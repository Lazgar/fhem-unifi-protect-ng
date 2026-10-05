##############################################
# $Id: 74_UnifiProtectNG.pm 0.1.0 2026-10-05 $
#
# FHEM module: UniFi Protect via the official Integration API (API key).
# IO / bridge device. Logical devices (cameras, sensors, lights, chimes, ...) are created as UnifiProtectNGDevice.
# License: GPL-2.0-or-later
#
package main;

use strict;
use warnings;

use JSON;
use Time::HiRes qw(gettimeofday);

use HttpUtils;
use DevIo;

my $UPNG_VERSION = '0.1.0';

# Model keys that are loaded from the API (list endpoint => modelKey)
my %UPNG_LISTS = (
  nvrs    => 'nvr',
  cameras => 'camera',
  sensors => 'sensor',
  lights  => 'light',
  chimes  => 'chime',
  viewers => 'viewer',
);

sub UnifiProtectNG_Initialize {
  my ($hash) = @_;

  $hash->{DefFn}      = 'UnifiProtectNG_Define';
  $hash->{UndefFn}    = 'UnifiProtectNG_Undef';
  $hash->{DeleteFn}   = 'UnifiProtectNG_Delete';
  $hash->{ShutdownFn} = 'UnifiProtectNG_Shutdown';
  $hash->{SetFn}      = 'UnifiProtectNG_Set';
  $hash->{GetFn}      = 'UnifiProtectNG_Get';
  $hash->{AttrFn}     = 'UnifiProtectNG_Attr';
  $hash->{ReadFn}     = 'UnifiProtectNG_Read';
  $hash->{ReadyFn}    = 'UnifiProtectNG_Ready';

  $hash->{Clients}    = 'UnifiProtectNGDevice';
  $hash->{MatchList}  = { '1:UnifiProtectNGDevice' => '^UProtNG:' };

  # FHEMWEB endpoint: live pictures (snapshots proxied with the API key, the key never reaches the browser)
  $data{FWEXT}{'/UnifiProtectNG'}{FUNC} = 'UnifiProtectNG_CGI';

  $hash->{AttrList}   = 'disable:1,0 verifySSL:0,1 autoCreate:1,0 apiPath '
                      . 'checkInterval refreshInterval wsEvents:1,0 wsDevices:1,0 '
                      . $readingFnAttributes;
}

# ---------------------------------------------------------------- define / undefine
sub UnifiProtectNG_Define {
  my ($hash, $def) = @_;
  my @a = split(/[ \t]+/, $def);

  return 'Usage: define <name> UnifiProtectNG <host[:port]>' if (@a != 3);

  my $name = $a[0];
  my ($host, $port) = split(/:/, $a[2], 2);
  $hash->{HOST}    = $host;
  $hash->{PORT}    = $port // 443;
  $hash->{VERSION} = $UPNG_VERSION;
  $hash->{NOTIFYDEV} = 'global';
  $hash->{STATE}   = 'initialized';
  $hash->{helper}  = {};

  RemoveInternalTimer($hash, 'UnifiProtectNG_Connect');
  InternalTimer(gettimeofday() + 3, 'UnifiProtectNG_Connect', $hash, 1);
  return undef;
}

sub UnifiProtectNG_Undef {
  my ($hash, $arg) = @_;
  UnifiProtectNG_Disconnect($hash);
  RemoveInternalTimer($hash);
  return undef;
}

sub UnifiProtectNG_Shutdown {
  my ($hash) = @_;
  UnifiProtectNG_Disconnect($hash);
  return undef;
}

sub UnifiProtectNG_Delete {
  my ($hash, $name) = @_;
  setKeyValue($name . '_apiKey', undef);
  return undef;
}

# ---------------------------------------------------------------- helpers
sub UnifiProtectNG_ApiKey {
  my ($hash) = @_;
  my ($err, $key) = getKeyValue($hash->{NAME} . '_apiKey');
  return $key;
}

sub UnifiProtectNG_BasePath {
  my ($hash) = @_;
  return AttrVal($hash->{NAME}, 'apiPath', '/proxy/protect/integration');
}

sub UnifiProtectNG_SslArgs {
  my ($hash) = @_;
  my $verify = AttrVal($hash->{NAME}, 'verifySSL', 0);
  return $verify ? {} : { SSL_verify_mode => 0 };
}

sub UnifiProtectNG_SetState {
  my ($hash, $state) = @_;
  return if (($hash->{STATE} // '') eq $state);
  readingsSingleUpdate($hash, 'state', $state, 1);
  $hash->{STATE} = $state;
}

# ---------------------------------------------------------------- REST
# UnifiProtectNG_Api($hash, $method, $path, $bodyHashOrUndef, $callback, $extra)
# callback: sub($hash, $json, $raw, $code, $err, $extra); $json undef for non JSON answers (e.g. snapshots)
sub UnifiProtectNG_Api {
  my ($hash, $method, $path, $body, $cb, $extra) = @_;
  my $name = $hash->{NAME};
  my $key  = UnifiProtectNG_ApiKey($hash);

  if (!$key) {
    UnifiProtectNG_SetState($hash, 'no apiKey');
    return 'no apiKey set (use: set ' . $name . ' apiKey <key>)';
  }

  my $url = 'https://' . $hash->{HOST} . ':' . $hash->{PORT} . UnifiProtectNG_BasePath($hash) . $path;
  my %hdr = ( 'X-API-KEY' => $key, 'Accept' => '*/*' );
  my $data;
  if (defined $body) {
    $hdr{'Content-Type'} = 'application/json';
    $data = encode_json($body);
  }

  my $param = {
    url        => $url,
    method     => $method,
    timeout    => 10,
    hash       => $hash,
    header     => \%hdr,
    sslargs    => UnifiProtectNG_SslArgs($hash),
    callback   => sub {
      my ($p, $err, $raw) = @_;
      UnifiProtectNG_ApiDone($hash, $p, $err, $raw, $cb, $extra);
    },
  };
  $param->{data} = $data if (defined $data);

  Log3 $name, 5, "$name: $method $url" . (defined $data ? " $data" : '');
  HttpUtils_NonblockingGet($param);
  return undef;
}

sub UnifiProtectNG_ApiDone {
  my ($hash, $param, $err, $raw, $cb, $extra) = @_;
  my $name = $hash->{NAME};
  my $code = $param->{code} // 0;

  if ($err) {
    Log3 $name, 3, "$name: request $param->{method} $param->{url} failed: $err" if (($hash->{helper}{lastErr} // '') ne $err);
    $hash->{helper}{lastErr} = $err;
    $hash->{helper}{apiFails}++;
    $cb->($hash, undef, undef, 0, $err, $extra) if ($cb);
    return;
  }
  delete $hash->{helper}{lastErr};
  $hash->{helper}{apiFails} = 0;

  if ($code == 401 || $code == 403) {
    Log3 $name, 2, "$name: API key rejected (HTTP $code). Create a key in the UniFi OS settings (Control Plane > Integrations) and set it with: set $name apiKey <key>"
      if (($hash->{STATE} // '') ne 'unauthorized');
    UnifiProtectNG_SetState($hash, 'unauthorized');
    UnifiProtectNG_Disconnect($hash);
    $cb->($hash, undef, $raw, $code, 'unauthorized', $extra) if ($cb);
    return;
  }

  my $json;
  if (defined $raw && $raw =~ /^\s*[\[{]/) {
    $json = eval { decode_json($raw) };
    Log3 $name, 3, "$name: JSON error on $param->{url}: $@" if ($@ && !$extra->{raw});
  }

  if ($code >= 400) {
    my $msg = ref($json) eq 'HASH' ? ($json->{error} // $json->{message} // '') : '';
    Log3 $name, 3, "$name: $param->{method} $param->{url} -> HTTP $code $msg";
  }

  $cb->($hash, $json, $raw, $code, undef, $extra) if ($cb);
}

# ---------------------------------------------------------------- connect / load
sub UnifiProtectNG_Connect {
  my ($hash) = @_;
  my $name = $hash->{NAME};

  RemoveInternalTimer($hash, 'UnifiProtectNG_Connect');
  return if (IsDisabled($name));

  UnifiProtectNG_Disconnect($hash);

  if (!UnifiProtectNG_ApiKey($hash)) {
    UnifiProtectNG_SetState($hash, 'no apiKey');
    Log3 $name, 2, "$name: no API key set (set $name apiKey <key>)" if (!$hash->{helper}{warnedNoKey}++);
    return;
  }

  UnifiProtectNG_SetState($hash, 'connecting');
  $hash->{helper}{gen} = ($hash->{helper}{gen} // 0) + 1;    # generation: ignores answers of older attempts

  my $gen = $hash->{helper}{gen};
  UnifiProtectNG_Api($hash, 'GET', '/v1/meta/info', undef, sub {
    my ($h, $json, $raw, $code, $err, $x) = @_;
    return if ($h->{helper}{gen} != $gen);
    if ($err || $code != 200 || ref($json) ne 'HASH') {
      return if (($h->{STATE} // '') eq 'unauthorized');
      UnifiProtectNG_SetState($h, 'disconnected');
      UnifiProtectNG_ScheduleRetry($h);
      return;
    }
    readingsBeginUpdate($h);
    readingsBulkUpdateIfChanged($h, 'protectVersion', $json->{applicationVersion} // '?');
    readingsEndUpdate($h, 1);
    UnifiProtectNG_LoadAll($h, $gen);
  });
}

sub UnifiProtectNG_ScheduleRetry {
  my ($hash) = @_;
  my $n = $hash->{helper}{retry} = ($hash->{helper}{retry} // 0) + 1;
  my $delay = (5, 10, 20, 30, 60)[$n > 5 ? 4 : $n - 1];
  RemoveInternalTimer($hash, 'UnifiProtectNG_Connect');
  InternalTimer(gettimeofday() + $delay, 'UnifiProtectNG_Connect', $hash, 0);
}

# loads all device lists, then (re)opens the websockets
sub UnifiProtectNG_LoadAll {
  my ($hash, $gen) = @_;
  my $name = $hash->{NAME};
  $gen //= $hash->{helper}{gen};

  my @eps = sort keys %UPNG_LISTS;
  my $pending = scalar @eps;
  my $ok = 1;

  foreach my $ep (@eps) {
    UnifiProtectNG_Api($hash, 'GET', "/v1/$ep", undef, sub {
      my ($h, $json, $raw, $code, $err, $x) = @_;
      return if ($h->{helper}{gen} != $gen);
      if (!$err && $code == 200 && (ref($json) eq 'ARRAY' || ref($json) eq 'HASH')) {
        my @items = ref($json) eq 'ARRAY' ? @$json : ($json);       # /v1/nvrs returns a single object
        my $n = 0;
        foreach my $item (@items) {
          next if (ref($item) ne 'HASH' || !defined $item->{id});
          $item->{modelKey} //= $UPNG_LISTS{$ep};
          UnifiProtectNG_DispatchDevice($h, $item, 'full');
          $n++;
        }
        readingsSingleUpdate($h, 'nr' . ucfirst($ep), $n, 0);
      } elsif ($err || $code == 0 || $code >= 500) {
        $ok = 0;                                                    # transport problem: retry the whole connect
      } else {
        # 404 (e.g. no chimes/viewers on this console) or another client error: not fatal, the other lists and websockets still work
        Log3 $name, 3, "$name: /v1/$ep not usable (HTTP $code), skipped";
      }
      return if (--$pending > 0);
      if ($ok) {
        $h->{helper}{retry} = 0;
        UnifiProtectNG_OpenWebsockets($h);
        UnifiProtectNG_SetState($h, 'opened') if (UnifiProtectNG_WsCount($h) == 0);   # without websockets (both attributes 0)
        $h->{helper}{lastFull} = time();
        UnifiProtectNG_StartWatchdog($h);
      } elsif (($h->{STATE} // '') ne 'unauthorized') {
        UnifiProtectNG_SetState($h, 'disconnected');
        UnifiProtectNG_ScheduleRetry($h);
      }
    });
  }
}

sub UnifiProtectNG_DispatchDevice {
  my ($hash, $item, $mode) = @_;
  my $id = $item->{id};
  return if (!defined $id);

  # remember the latest known data of every device: autocreate defines devices after the first message, the device replays it
  my $last = ($hash->{helper}{last}{$id} //= {});
  $last->{$_} = $item->{$_} for keys %$item;
  delete $hash->{helper}{last}{$id} if ($mode eq 'remove');

  my $known = $modules{UnifiProtectNGDevice}{defptr}{$id};
  if (!$known && !AttrVal($hash->{NAME}, 'autoCreate', 1)) {
    $hash->{helper}{unknown}{$id} = $item->{name} // $item->{modelKey} // '?';
    return;
  }
  Dispatch($hash, 'UProtNG:' . encode_json({ kind => 'device', mode => $mode, item => $item }), undef);
}

sub UnifiProtectNG_DispatchEvent {
  my ($hash, $item) = @_;
  Dispatch($hash, 'UProtNG:' . encode_json({ kind => 'event', item => $item }), undef, 1);
}

# ---------------------------------------------------------------- websockets
sub UnifiProtectNG_WsCount {
  my ($hash) = @_;
  return scalar(keys %{ $hash->{helper}{ws} // {} });
}

sub UnifiProtectNG_OpenWebsockets {
  my ($hash) = @_;
  my $name = $hash->{NAME};
  my @kinds;
  push @kinds, 'events'  if (AttrVal($name, 'wsEvents', 1));
  push @kinds, 'devices' if (AttrVal($name, 'wsDevices', 1));
  UnifiProtectNG_OpenWs($hash, $_) for @kinds;
}

sub UnifiProtectNG_OpenWs {
  my ($hash, $kind) = @_;
  my $name = $hash->{NAME};
  my $key  = UnifiProtectNG_ApiKey($hash);

  return if ($hash->{helper}{ws}{$kind});

  my $cname = "$name.ws.$kind";
  my $chash = {
    NAME          => $cname,
    TYPE          => $hash->{TYPE},
    PORT          => $hash->{PORT},
    DeviceName    => "wss:$hash->{HOST}:$hash->{PORT}" . UnifiProtectNG_BasePath($hash) . "/v1/subscribe/$kind",
    header        => { 'X-API-KEY' => $key },
    sslargs       => UnifiProtectNG_SslArgs($hash),
    devioLoglevel => 4,
    phash         => $hash,
    wskind        => $kind,
    TEMPORARY     => 1,
    NR            => $devcount++,
    gen           => $hash->{helper}{gen},
    nrPackets     => 0,
  };
  $attr{$cname}{comment} = 'do NOT delete (websocket of ' . $name . ')';
  $attr{$cname}{room}    = 'hidden';
  $defs{$cname}          = $chash;
  $hash->{helper}{ws}{$kind} = $chash;

  DevIo_OpenDev($chash, 0, undef, sub {
    my ($ch, $err) = @_;
    if ($err) {
      Log3 $name, 3, "$name: websocket $kind: $err";
      UnifiProtectNG_WsClosed($ch);
      return;
    }
    $hash->{helper}{wsUp}{$kind} = 1;
    my $need = (AttrVal($name, 'wsEvents', 1) ? 1 : 0) + (AttrVal($name, 'wsDevices', 1) ? 1 : 0);
    if (scalar(keys %{ $hash->{helper}{wsUp} }) >= $need) {
      UnifiProtectNG_SetState($hash, 'opened');
      Log3 $name, 3, "$name: connected to Protect " . ReadingsVal($name, 'protectVersion', '?') if (!$hash->{helper}{connLogged}++);
    }
  });
}

sub UnifiProtectNG_CloseWs {
  my ($hash, $kind) = @_;
  delete $hash->{helper}{wsUp}{$kind};
  my $ch = delete $hash->{helper}{ws}{$kind};
  return if (!$ch);
  DevIo_CloseDev($ch);
  # DevIo remembers a "just closed" state and skips the next open: clear it
  delete $ch->{DevIoJustClosed};
  delete $ch->{NEXT_OPEN};
  delete $attr{ $ch->{NAME} };
  delete $defs{ $ch->{NAME} };
}

sub UnifiProtectNG_Disconnect {
  my ($hash) = @_;
  UnifiProtectNG_CloseWs($hash, $_) for keys %{ $hash->{helper}{ws} // {} };
  RemoveInternalTimer($hash, 'UnifiProtectNG_Watchdog');
  $hash->{helper}{gen} = ($hash->{helper}{gen} // 0) + 1 if ($hash->{helper}{ws});
}

sub UnifiProtectNG_Ready {
  my ($hash) = @_;
  return undef;    # reconnects are handled by UnifiProtectNG_WsClosed (back-off), not by DevIo
}

sub UnifiProtectNG_Read {
  my ($hash) = @_;
  my $buf = DevIo_SimpleRead($hash);

  if (!defined $buf) {                       # connection closed
    UnifiProtectNG_WsClosed($hash);
    return;
  }
  return if ($buf eq '');

  my $p = $hash->{phash} or return;
  my $name = $p->{NAME};
  $hash->{nrPackets}++;
  $p->{helper}{lastPacket} = time();
  $p->{nrPackets} = ($p->{nrPackets} // 0) + 1;

  my $json = eval { decode_json($buf) };
  if (ref($json) ne 'HASH' || ref($json->{item}) ne 'HASH') {
    Log3 $name, 4, "$name: websocket $hash->{wskind}: unparsable message: " . substr($buf, 0, 200);
    return;
  }
  Log3 $name, 5, "$name: websocket $hash->{wskind}: $buf";

  if ($hash->{wskind} eq 'events') {
    UnifiProtectNG_DispatchEvent($p, $json->{item});
  } else {
    my $t = $json->{type} // 'update';
    if ($t eq 'remove') {
      UnifiProtectNG_DispatchDevice($p, { %{ $json->{item} }, _removed => 1 }, 'remove');
    } else {
      UnifiProtectNG_DispatchDevice($p, $json->{item}, $t eq 'add' ? 'full' : 'update');
    }
  }
}

sub UnifiProtectNG_WsClosed {
  my ($ch) = @_;
  my $p = $ch->{phash} or return;
  my $name = $p->{NAME};
  my $kind = $ch->{wskind};

  return if (!$p->{helper}{ws} || ($p->{helper}{ws}{$kind} // 0) != $ch);   # already replaced / disconnected on purpose
  Log3 $name, 3, "$name: websocket $kind closed, reconnecting";

  UnifiProtectNG_CloseWs($p, $kind);
  UnifiProtectNG_SetState($p, 'disconnected');
  # full reconnect: fresh state (devices may have changed while the connection was down) and one single retry loop
  RemoveInternalTimer($p, 'UnifiProtectNG_Connect');
  InternalTimer(gettimeofday() + 5, 'UnifiProtectNG_Connect', $p, 0);
}

# ---------------------------------------------------------------- watchdog
sub UnifiProtectNG_StartWatchdog {
  my ($hash) = @_;
  RemoveInternalTimer($hash, 'UnifiProtectNG_Watchdog');
  InternalTimer(gettimeofday() + AttrVal($hash->{NAME}, 'checkInterval', 60), 'UnifiProtectNG_Watchdog', $hash, 0);
}

# every checkInterval seconds: liveness request. Several failed requests => full reconnect.
# every refreshInterval seconds: reload all lists (catches missed updates).
sub UnifiProtectNG_Watchdog {
  my ($hash) = @_;
  my $name = $hash->{NAME};
  return if (IsDisabled($name));
  UnifiProtectNG_StartWatchdog($hash);

  my $gen = $hash->{helper}{gen};
  my $wsDown = (UnifiProtectNG_WsCount($hash) < ((AttrVal($name, 'wsEvents', 1) ? 1 : 0) + (AttrVal($name, 'wsDevices', 1) ? 1 : 0)));

  UnifiProtectNG_Api($hash, 'GET', '/v1/meta/info', undef, sub {
    my ($h, $json, $raw, $code, $err, $x) = @_;
    return if ($h->{helper}{gen} != $gen);
    if ($err || $code != 200) {
      if (++$h->{helper}{wdFails} >= 2 && ($h->{STATE} // '') ne 'unauthorized') {
        Log3 $name, 3, "$name: watchdog: Protect not reachable ($h->{helper}{wdFails} failed checks), reconnecting";
        $h->{helper}{wdFails} = 0;
        UnifiProtectNG_SetState($h, 'disconnected');
        UnifiProtectNG_Connect($h);
      }
      return;
    }
    $h->{helper}{wdFails} = 0;
    if ($wsDown && ($h->{STATE} // '') ne 'connecting') {
      Log3 $name, 3, "$name: watchdog: websocket missing, reconnecting";
      UnifiProtectNG_Connect($h);
      return;
    }
    my $ri = AttrVal($name, 'refreshInterval', 3600);
    if ($ri && time() - ($h->{helper}{lastFull} // 0) >= $ri) {
      $h->{helper}{lastFull} = time();
      UnifiProtectNG_LoadAllRefresh($h);
    }
  });
}

# refresh without touching the websockets
sub UnifiProtectNG_LoadAllRefresh {
  my ($hash) = @_;
  foreach my $ep (sort keys %UPNG_LISTS) {
    UnifiProtectNG_Api($hash, 'GET', "/v1/$ep", undef, sub {
      my ($h, $json, $raw, $code, $err, $x) = @_;
      return if ($err || $code != 200 || (ref($json) ne 'ARRAY' && ref($json) ne 'HASH'));
      foreach my $item (ref($json) eq 'ARRAY' ? @$json : ($json)) {
        next if (ref($item) ne 'HASH' || !defined $item->{id});
        $item->{modelKey} //= $UPNG_LISTS{$ep};
        UnifiProtectNG_DispatchDevice($h, $item, 'full');
      }
    });
  }
}

# ---------------------------------------------------------------- FHEMWEB: snapshot proxy for live pictures
# GET <FHEMWEB>/UnifiProtectNG?dev=<UnifiProtectNGDevice>[&hq=1]  -> image/jpeg
# The newest picture is kept in a small cache per camera. A request is answered immediately from the cache (works for every HTTP client)
# and starts a non-blocking refresh for the next request. Only the very first request waits for the console (answered asynchronously,
# which needs a keep-alive connection like a browser uses). The API key never reaches the browser.
sub UnifiProtectNG_Fetch {
  my ($io, $id, $hq, $cb) = @_;
  my $s = ($io->{helper}{snap}{$id}{ $hq ? 'hq' : 'sd' } //= {});
  return if ($s->{pending} && time() - $s->{pending} < 15);
  $s->{pending} = time();
  my $q = $hq ? '?highQuality=true' : '';
  UnifiProtectNG_Api($io, 'GET', "/v1/cameras/$id/snapshot$q", undef, sub {
    my ($h, $json, $raw, $code, $err) = @_;
    $s->{pending} = 0;
    if (!$err && $code == 200 && defined $raw && length($raw) >= 100) {
      $s->{data} = $raw;
      $s->{ts}   = gettimeofday();
      $cb->($raw, undef) if ($cb);
    } else {
      $cb->(undef, $err // "HTTP $code") if ($cb);
    }
  }, { raw => 1 });
}

sub UnifiProtectNG_CGI {
  my ($url) = @_;
  my ($cmd, $c) = FW_digestCgi($url);
  my $cname = $FW_cname;
  my $dev   = $FW_webArgs{dev} // '';
  my $hq    = $FW_webArgs{hq} ? 1 : 0;
  my $d     = $defs{$dev};

  my $reply = sub {
    my ($code, $type, $body) = @_;
    my $cl = $defs{$cname} ? $defs{$cname}{CD} : undef;
    return if (!$cl);
    my $out = "HTTP/1.1 $code\r\nContent-Type: $type\r\nContent-Length: " . length($body) . "\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n" . $body;
    my $off = 0;                                                    # real snapshots are ~1 MB: the socket is non-blocking, so loop until everything is written
    my $end = gettimeofday() + 8;
    while ($off < length($out) && gettimeofday() < $end) {
      my $n = syswrite($cl, $out, 65536, $off);
      if (defined $n) { $off += $n; next; }
      last if (!($!{EAGAIN} || $!{EWOULDBLOCK}));
      my $w = '';
      vec($w, fileno($cl), 1) = 1;
      select(undef, $w, undef, 0.5);
    }
  };

  if (!$d || ($d->{TYPE} // '') ne 'UnifiProtectNGDevice' || ($d->{MODELKEY} // '') ne 'camera' || !$d->{IODev}) {
    $reply->('400 Bad Request', 'text/plain', 'unknown device');
    return undef;
  }
  my $io = $d->{IODev};
  my $id = $d->{PROTECTID};

  my $s = $io->{helper}{snap}{$id}{ $hq ? 'hq' : 'sd' };
  if ($s && $s->{data} && time() - $s->{ts} < 30) {                 # fresh enough: answer now, refresh in the background
    $reply->('200 OK', 'image/jpeg', $s->{data});
    UnifiProtectNG_Fetch($io, $id, $hq) if (gettimeofday() - $s->{ts} > 0.4 && ($io->{STATE} // '') eq 'opened');
    return undef;
  }
  if (($io->{STATE} // '') ne 'opened') {
    $reply->('503 Service Unavailable', 'text/plain', 'bridge not connected');
    return undef;
  }
  UnifiProtectNG_Fetch($io, $id, $hq, sub {                         # cold start: answer when the picture arrives
    my ($raw, $err) = @_;
    $raw ? $reply->('200 OK', 'image/jpeg', $raw) : $reply->('502 Bad Gateway', 'text/plain', "snapshot failed: $err");
  });
  return undef;
}

# ---------------------------------------------------------------- set / get / attr
sub UnifiProtectNG_Set {
  my ($hash, $name, $cmd, @args) = @_;
  my $list = 'apiKey reconnect:noArg refresh:noArg';

  if ($cmd eq 'apiKey') {
    return 'Usage: set ' . $name . ' apiKey <key>' if (!@args);
    setKeyValue($name . '_apiKey', join(' ', @args));
    delete $hash->{helper}{warnedNoKey};
    UnifiProtectNG_SetState($hash, 'initialized');
    RemoveInternalTimer($hash, 'UnifiProtectNG_Connect');
    InternalTimer(gettimeofday() + 1, 'UnifiProtectNG_Connect', $hash, 0);
    return undef;
  }
  if ($cmd eq 'reconnect') {
    UnifiProtectNG_Connect($hash);
    return undef;
  }
  if ($cmd eq 'refresh') {
    UnifiProtectNG_LoadAllRefresh($hash);
    return undef;
  }
  return "Unknown argument $cmd, choose one of $list";
}

sub UnifiProtectNG_Get {
  my ($hash, $name, $cmd, @args) = @_;
  my $list = 'devices:noArg info:noArg';

  if ($cmd eq 'devices') {
    my @out;
    foreach my $id (sort keys %{ $modules{UnifiProtectNGDevice}{defptr} // {} }) {
      my $d = $modules{UnifiProtectNGDevice}{defptr}{$id};
      next if (!$d || ($d->{IODev} && $d->{IODev} != $hash));
      push @out, sprintf('%-28s %-8s %s', $d->{NAME}, $d->{MODELKEY} // '?', $id);
    }
    my $u = $hash->{helper}{unknown} // {};
    push @out, sprintf('%-28s %-8s %s', '(not defined: autoCreate=0)', '', "$_ ($u->{$_})") for sort keys %$u;
    return @out ? join("\n", @out) : 'no devices yet';
  }
  if ($cmd eq 'info') {
    return join("\n", "module version: $UPNG_VERSION",
                      'protect version: ' . ReadingsVal($name, 'protectVersion', '?'),
                      'state: ' . ($hash->{STATE} // '?'),
                      'websockets: ' . join(',', sort keys %{ $hash->{helper}{ws} // {} }),
                      'packets: ' . ($hash->{nrPackets} // 0));
  }
  return "Unknown argument $cmd, choose one of $list";
}

sub UnifiProtectNG_Attr {
  my ($cmd, $name, $attrName, $attrVal) = @_;
  my $hash = $defs{$name};

  if ($attrName eq 'disable') {
    if ($cmd eq 'set' && $attrVal) {
      UnifiProtectNG_Disconnect($hash);
      UnifiProtectNG_SetState($hash, 'disabled');
    } else {
      RemoveInternalTimer($hash, 'UnifiProtectNG_Connect');
      InternalTimer(gettimeofday() + 1, 'UnifiProtectNG_Connect', $hash, 0) if ($init_done);
    }
  } elsif ($attrName =~ /^(verifySSL|apiPath|wsEvents|wsDevices)$/ && $init_done) {
    RemoveInternalTimer($hash, 'UnifiProtectNG_Connect');
    InternalTimer(gettimeofday() + 2, 'UnifiProtectNG_Connect', $hash, 0);
  } elsif ($attrName =~ /^(checkInterval|refreshInterval)$/) {
    return "$attrName must be a number of seconds" if ($cmd eq 'set' && $attrVal !~ /^\d+$/);
  }
  return undef;
}

1;

=pod
=item device
=item summary    UniFi Protect via the official Integration API (API key): cameras, sensors, lights, chimes
=item summary_DE UniFi Protect &uuml;ber die offizielle Integration-API (API-Schl&uuml;ssel): Kameras, Sensoren, Lichter, Gong
=begin html

<a name="UnifiProtectNG"></a>
<h3>UnifiProtectNG</h3>
<ul>
  Connects FHEM to a UniFi Protect console (UDM/UNVR/Cloud Gateway) using the official Integration API.
  Cameras, sensors, lights, chimes, viewers and NVR are created automatically as <a href="#UnifiProtectNGDevice">UnifiProtectNGDevice</a>.
  Events (motion, smart detections, ring, sensor events) arrive in real time over websockets.
  <br><br>
  <a name="UnifiProtectNGdefine"></a>
  <b>Define</b>
  <ul>
    <code>define &lt;name&gt; UnifiProtectNG &lt;host[:port]&gt;</code><br>
    Create an API key in the UniFi OS web interface (<i>Settings &rarr; Control Plane &rarr; Integrations</i>) and store it with
    <code>set &lt;name&gt; apiKey &lt;key&gt;</code>. The key is kept in FHEM's key store, not in fhem.cfg.
  </ul>
  <a name="UnifiProtectNGset"></a>
  <b>Set</b>
  <ul>
    <li>apiKey &lt;key&gt;: store the API key and (re)connect</li>
    <li>reconnect: close connections and connect again</li>
    <li>refresh: reload all device lists</li>
  </ul>
  <a name="UnifiProtectNGget"></a>
  <b>Get</b>
  <ul>
    <li>devices: list known devices</li>
    <li>info: module/Protect version and connection details</li>
  </ul>
  <a name="UnifiProtectNGattr"></a>
  <b>Attributes</b>
  <ul>
    <li>disable 1|0: disable the connection</li>
    <li>verifySSL 1|0: verify the console's TLS certificate (default 0, consoles use self-signed certificates)</li>
    <li>autoCreate 1|0: create devices automatically (default 1)</li>
    <li>apiPath: API base path, default <code>/proxy/protect/integration</code></li>
    <li>checkInterval: seconds between liveness checks (default 60)</li>
    <li>refreshInterval: seconds between full list reloads (default 3600, 0 = never)</li>
    <li>wsEvents 1|0, wsDevices 1|0: use the event / device-update websocket (default 1)</li>
  </ul>
</ul>

=end html
=cut
