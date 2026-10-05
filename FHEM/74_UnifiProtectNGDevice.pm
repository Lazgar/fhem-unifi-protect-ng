##############################################
# $Id: 74_UnifiProtectNGDevice.pm 0.1.0 2026-10-05 $
#
# FHEM module: logical device (camera, sensor, light, chime, viewer, NVR, ...) of a UnifiProtectNG bridge.
# License: GPL-2.0-or-later
#
package main;

use strict;
use warnings;

use JSON;
use Time::HiRes qw(gettimeofday);
use POSIX qw(strftime);

my %UPNG_API_PATH = (
  camera => 'cameras',
  sensor => 'sensors',
  light  => 'lights',
  chime  => 'chimes',
  viewer => 'viewers',
);

my @UPNG_VIDEO_MODES = qw(default highFps sport slowShutter lprReflex lprNoneReflex);
my @UPNG_OBJECT_TYPES = qw(person vehicle package licensePlate face animal);

# friendly names for frequently used readings (everything else is flattened generically)
my %UPNG_ALIAS = (
  'ledSettings_isEnabled'            => 'statusLed',
  'batteryStatus_percentage'         => 'batteryPercentage',
  'batteryStatus_isLow'              => 'batteryLow',
  'stats_temperature_value'          => 'temperature',
  'stats_humidity_value'             => 'humidity',
  'stats_light_value'                => 'illuminance',
  'smartDetectSettings_objectTypes'  => 'smartDetectObjectTypes',
  'smartDetectSettings_audioTypes'   => 'smartDetectAudioTypes',
  'lightDeviceSettings_ledLevel'     => 'ledLevel',
  'lightDeviceSettings_pirSensitivity' => 'pirSensitivity',
  'lightDeviceSettings_pirDuration'  => 'pirDuration',
  'lightDeviceSettings_isIndicatorEnabled' => 'indicator',
  'lightModeSettings_mode'           => 'mode',
);

sub UnifiProtectNGDevice_Initialize {
  my ($hash) = @_;

  $hash->{DefFn}    = 'UnifiProtectNGDevice_Define';
  $hash->{UndefFn}  = 'UnifiProtectNGDevice_Undef';
  $hash->{SetFn}    = 'UnifiProtectNGDevice_Set';
  $hash->{GetFn}    = 'UnifiProtectNGDevice_Get';
  $hash->{AttrFn}   = 'UnifiProtectNGDevice_Attr';
  $hash->{ParseFn}  = 'UnifiProtectNGDevice_Parse';
  $hash->{Match}    = '^UProtNG:';

  $hash->{FW_detailFn}  = 'UnifiProtectNGDevice_detailFn';
  $hash->{FW_summaryFn} = 'UnifiProtectNGDevice_summaryFn';

  $hash->{AttrList} = 'disable:1,0 snapshotDir eventResetTime liveView:1,0 liveWidth liveInterval liveInSummary:1,0 '
                    . $readingFnAttributes;
}

# ---------------------------------------------------------------- define
sub UnifiProtectNGDevice_Define {
  my ($hash, $def) = @_;
  my @a = split(/[ \t]+/, $def);

  return 'Usage: define <name> UnifiProtectNGDevice <modelKey>:<id>' if (@a != 3 || $a[2] !~ /^([A-Za-z]+):(\S+)$/);
  my ($model, $id) = ($1, $2);
  my $name = $a[0];

  my $d = $modules{UnifiProtectNGDevice}{defptr}{$id};
  return "UnifiProtectNGDevice for $id already defined as $d->{NAME}" if ($d && $d->{NAME} ne $name);

  $hash->{MODELKEY}  = $model;
  $hash->{PROTECTID} = $id;
  $hash->{STATE}     = 'defined';
  $modules{UnifiProtectNGDevice}{defptr}{$id} = $hash;

  AssignIoPort($hash);
  # autocreate defines the device after the first message: apply the data the bridge remembered for this id
  InternalTimer(gettimeofday() + 0.3, 'UnifiProtectNGDevice_Initial', $hash, 0);
  return undef;
}

sub UnifiProtectNGDevice_Undef {
  my ($hash, $arg) = @_;
  RemoveInternalTimer($hash);
  delete $modules{UnifiProtectNGDevice}{defptr}{ $hash->{PROTECTID} } if ($hash->{PROTECTID});
  return undef;
}

sub UnifiProtectNGDevice_Initial {
  my ($hash) = @_;
  my $io = $hash->{IODev} or return;
  my $item = $io->{helper}{last}{ $hash->{PROTECTID} } or return;
  UnifiProtectNGDevice_ApplyDevice($hash, $item);
}

# ---------------------------------------------------------------- parse (called by Dispatch of the bridge)
sub UnifiProtectNGDevice_Parse {
  my ($io, $msg) = @_;
  $msg =~ s/^UProtNG://;
  my $m = eval { decode_json($msg) };
  return '' if (ref($m) ne 'HASH' || ref($m->{item}) ne 'HASH');
  my $item = $m->{item};

  if (($m->{kind} // '') eq 'event') {
    my $dev = $item->{device};
    my $h = defined($dev) ? $modules{UnifiProtectNGDevice}{defptr}{$dev} : undef;
    return '' if (!$h);                          # events of unknown devices are ignored
    UnifiProtectNGDevice_ApplyEvent($h, $item);
    return $h->{NAME};
  }

  my $id = $item->{id};
  return '' if (!defined $id);
  my $h = $modules{UnifiProtectNGDevice}{defptr}{$id};

  if (!$h) {
    return '' if ($item->{_removed} || ($m->{mode} // '') eq 'remove');
    my $model = $item->{modelKey} // 'device';
    my $nm = $item->{name} // $id;
    $nm =~ s/[^A-Za-z0-9_]/_/g;
    $nm = substr($nm, 0, 40);
    return "UNDEFINED UProtNG_${model}_$nm UnifiProtectNGDevice $model:$id";
  }

  if ($item->{_removed} || ($m->{mode} // '') eq 'remove') {
    readingsSingleUpdate($h, 'state', 'removed', 1);
    return $h->{NAME};
  }
  UnifiProtectNGDevice_ApplyDevice($h, $item);
  return $h->{NAME};
}

# ---------------------------------------------------------------- device data -> readings
sub UnifiProtectNGDevice_Time {
  my ($ms) = @_;
  return $ms if (!defined $ms || $ms !~ /^\d{11,}$/);
  return strftime('%Y-%m-%d %H:%M:%S', localtime($ms / 1000));
}

sub UnifiProtectNGDevice_Flatten {
  my ($prefix, $val, $out, $depth, $maxdepth) = @_;
  if (ref($val) eq 'HASH') {
    return if ($depth >= $maxdepth);
    foreach my $k (sort keys %$val) {
      my $key = $prefix eq '' ? $k : $prefix . '_' . $k;
      UnifiProtectNGDevice_Flatten($key, $val->{$k}, $out, $depth + 1, $maxdepth);
    }
  } elsif (ref($val) eq 'ARRAY') {
    my @s = grep { !ref($_) } @$val;
    $out->{$prefix} = join(',', @s) if (@s == @$val);
    $out->{$prefix} = encode_json($val) if (@s != @$val && length(encode_json($val)) < 300);
  } elsif (JSON::is_bool($val)) {
    $out->{$prefix} = $val ? 1 : 0;
  } elsif (defined $val) {
    $out->{$prefix} = $val;
  }
}

sub UnifiProtectNGDevice_ApplyDevice {
  my ($hash, $item) = @_;
  my %flat;
  UnifiProtectNGDevice_Flatten('', $item, \%flat, 0, 4);
  delete @flat{qw(id modelKey)};

  $flat{state} = lc($flat{state}) if (defined $flat{state});

  readingsBeginUpdate($hash);
  foreach my $k (sort keys %flat) {
    my $name = $UPNG_ALIAS{$k} // $k;
    my $v = $flat{$k};
    $v = UnifiProtectNGDevice_Time($v) if ($k =~ /(At|^lastMotion)$/);
    $v = ($v ? 'on' : 'off') if ($k eq 'ledSettings_isEnabled' || $k eq 'lightDeviceSettings_isIndicatorEnabled');
    readingsBulkUpdateIfChanged($hash, $name, $v);
  }
  readingsEndUpdate($hash, 1);
  $hash->{helper}{api} = $item;      # last known full/partial data (used for set commands, features)

  if (ref($item->{featureFlags}) eq 'HASH') {
    $hash->{FEATURES} = join(',', grep { $item->{featureFlags}{$_} && !ref($item->{featureFlags}{$_}) } sort keys %{ $item->{featureFlags} });
  }
  $hash->{NAME_PROTECT} = $item->{name} if (defined $item->{name});
}

# ---------------------------------------------------------------- events -> readings
sub UnifiProtectNGDevice_ApplyEvent {
  my ($hash, $e) = @_;
  my $name = $hash->{NAME};
  my $type = $e->{type} // 'unknown';
  my $ongoing = defined($e->{end}) ? 0 : 1;
  my $state = $ongoing ? 'on' : 'off';
  my $start = UnifiProtectNGDevice_Time($e->{start});
  my $eid = $e->{id} // '';

  readingsBeginUpdate($hash);
  readingsBulkUpdate($hash, 'lastEvent', $type);
  readingsBulkUpdate($hash, 'lastEventTime', $start) if (defined $start);

  if ($type eq 'motion' || $type eq 'sensorMotion') {
    readingsBulkUpdateIfChanged($hash, 'motion', $state);
    readingsBulkUpdate($hash, 'lastMotion', $start) if ($ongoing && defined $start);
  } elsif ($type =~ /^(smartDetectZone|smartDetectLine|smartDetectLoiterZone|smartAudioDetect)$/) {
    my $kind = { smartDetectZone => 'zone', smartDetectLine => 'line', smartDetectLoiterZone => 'loiter', smartAudioDetect => 'audio' }->{$type};
    my @types = ref($e->{smartDetectTypes}) eq 'ARRAY' ? @{ $e->{smartDetectTypes} } : ();
    readingsBulkUpdateIfChanged($hash, "smartDetect_$kind", $state);
    foreach my $t (@types) { readingsBulkUpdateIfChanged($hash, "smartDetect_$t", $state); }
    if ($ongoing) {
      $hash->{helper}{ongoing}{$eid} = { types => [@types], kind => $kind };
      readingsBulkUpdate($hash, 'lastSmartDetect', $start) if (defined $start);
      readingsBulkUpdate($hash, 'lastSmartDetectTypes', join(',', @types)) if (@types);
    } else {
      delete $hash->{helper}{ongoing}{$eid};
    }
    my $any = scalar(keys %{ $hash->{helper}{ongoing} // {} }) ? 'on' : 'off';
    readingsBulkUpdateIfChanged($hash, 'smartDetected', $any);
  } elsif ($type eq 'ring') {
    readingsBulkUpdateIfChanged($hash, 'ring', $state);
    readingsBulkUpdate($hash, 'lastRing', $start) if ($ongoing && defined $start);
  } elsif ($type eq 'lightMotion') {
    readingsBulkUpdate($hash, 'lightMotion', 'on');
    readingsBulkUpdate($hash, 'lastMotion', $start) if (defined $start);
  } elsif ($type eq 'sensorOpened') {
    readingsBulkUpdateIfChanged($hash, 'contact', 'open');
  } elsif ($type eq 'sensorClosed') {
    readingsBulkUpdateIfChanged($hash, 'contact', 'closed');
  } elsif ($type eq 'sensorAlarm') {
    readingsBulkUpdateIfChanged($hash, 'alarm', $state);
  } elsif ($type eq 'sensorWaterLeak') {
    readingsBulkUpdateIfChanged($hash, 'leak', $state);
  } elsif ($type eq 'sensorTamper') {
    readingsBulkUpdateIfChanged($hash, 'tamper', $state);
  } elsif ($type eq 'sensorBatteryLow') {
    readingsBulkUpdateIfChanged($hash, 'batteryLow', $state eq 'on' ? 1 : 0);
  } elsif ($type eq 'sensorExtremeValues') {
    readingsBulkUpdate($hash, 'extremeValue', ref($e->{metadata}) ? encode_json($e->{metadata}) : 'on');
  } elsif ($type eq 'sensorSmokeTest') {
    readingsBulkUpdateIfChanged($hash, 'smokeTest', $state);
  } else {
    readingsBulkUpdateIfChanged($hash, "event_$type", $state);       # unknown/new event types: stay open for future models
  }
  readingsEndUpdate($hash, 1);

  # safety net: if an end event is lost, reset after eventResetTime seconds
  RemoveInternalTimer($hash, 'UnifiProtectNGDevice_ResetEvents');
  my $rt = AttrVal($name, 'eventResetTime', 300);
  InternalTimer(gettimeofday() + $rt, 'UnifiProtectNGDevice_ResetEvents', $hash, 0) if ($rt && $ongoing);
}

sub UnifiProtectNGDevice_ResetEvents {
  my ($hash) = @_;
  readingsBeginUpdate($hash);
  foreach my $r (keys %{ $hash->{READINGS} // {} }) {
    next if ($r !~ /^(motion|ring|alarm|leak|tamper|smokeTest|smartDetected|smartDetect_\w+|lightMotion)$/);
    next if (($hash->{READINGS}{$r}{VAL} // '') ne 'on');
    readingsBulkUpdate($hash, $r, 'off');
  }
  readingsEndUpdate($hash, 1);
  $hash->{helper}{ongoing} = {};
}

# ---------------------------------------------------------------- live picture in FHEMWEB (detail view / room summary)
# Refreshes a snapshot every liveInterval ms (default 1000) through the bridge's CGI; pauses while the browser tab is hidden.
sub UnifiProtectNGDevice_Live {
  my ($d, $width, $force) = @_;
  my $h = $defs{$d};
  return '' if (!$h || ($h->{MODELKEY} // '') ne 'camera' || !$h->{IODev});
  return '' if (AttrVal($d, 'liveView', 1) eq '0');
  my $iv = AttrVal($d, 'liveInterval', 1000);
  $iv = 1000 if ($iv !~ /^\d+$/ || $iv < 200);
  $width = AttrVal($d, 'liveWidth', $width // 640) if (!$force);
  $width = 640 if (!defined $width || $width !~ /^\d+$/);
  (my $id = "upng_$d") =~ s/[^A-Za-z0-9_]/_/g;
  my $base = "$FW_ME/UnifiProtectNG?dev=$d&width=$width";
  return "<div class='upngLive'><img id='$id' width='$width' style='display:block;max-width:100%;height:auto'>"
       . "<script type='text/javascript'>(function(){var img=document.getElementById('$id');var busy=false;"
       . "function load(){if(!document.body.contains(img))return;"
       . "if(document.hidden||busy){setTimeout(load,300);return;}"
       . "busy=true;var n=new Image();"
       . "n.onload=function(){img.src=n.src;busy=false;setTimeout(load,$iv);};"
       . "n.onerror=function(){busy=false;setTimeout(load,5000);};"
       . "n.src='$base&ts='+Date.now();}load();})();</script></div>";
}

# Overview of several cameras, e.g. for a weblink:
#   define wl_Kameras weblink htmlCode {UnifiProtectNG_2html('System_Unifi_ProtectNG','Garage,Eingang',400)}
# $cams: comma separated FHEM device names or Protect ids (empty = all cameras that are connected); $width in px per picture
sub UnifiProtectNG_2html {
  my ($io, $cams, $width) = @_;
  $io = $io->{NAME} if (ref($io) eq 'HASH');
  return 'no such bridge' if (!$io || !$defs{$io});
  $width = 320 if (!$width || $width !~ /^\d+$/);
  my @list;
  if (defined $cams && $cams ne '') {
    foreach my $c (split(/\s*,\s*/, $cams)) {
      my $d = $defs{$c} ? $c : undef;
      $d //= ($modules{UnifiProtectNGDevice}{defptr}{$c} // {})->{NAME};
      push @list, $d if ($d);
    }
  } else {
    foreach my $k (sort keys %{ $modules{UnifiProtectNGDevice}{defptr} // {} }) {
      my $dh = $modules{UnifiProtectNGDevice}{defptr}{$k};
      next if (!$dh || ($dh->{MODELKEY} // '') ne 'camera' || ($dh->{IODev} && $dh->{IODev}{NAME} ne $io));
      next if (lc(ReadingsVal($dh->{NAME}, 'state', '')) eq 'disconnected');
      push @list, $dh->{NAME};
    }
  }
  return 'no cameras' if (!@list);
  return "<div style='display:flex;flex-wrap:wrap;align-items:flex-start;gap:4px'>" . join('', map { UnifiProtectNGDevice_Live($_, $width, 1) } @list) . "</div>";
}

sub UnifiProtectNGDevice_detailFn {
  my ($FW_wname, $d, $room, $pageHash) = @_;
  return UnifiProtectNGDevice_Live($d, 640);
}

sub UnifiProtectNGDevice_summaryFn {
  my ($FW_wname, $d, $room, $pageHash) = @_;
  return '' if (AttrVal($d, 'liveInSummary', 0) ne '1');
  return UnifiProtectNGDevice_Live($d, 320);
}

# ---------------------------------------------------------------- set / get
sub UnifiProtectNGDevice_Patch {
  my ($hash, $body, $label, $cb) = @_;
  my $io = $hash->{IODev} or return 'no IODev';
  my $path = $UPNG_API_PATH{ $hash->{MODELKEY} } or return "model $hash->{MODELKEY} cannot be changed through the API";
  UnifiProtectNG_Api($io, 'PATCH', "/v1/$path/$hash->{PROTECTID}", $body, sub {
    my ($h, $json, $raw, $code, $err, $x) = @_;
    if ($err || $code >= 400) {
      Log3 $hash->{NAME}, 2, "$hash->{NAME}: $label failed: " . ($err // "HTTP $code") . ' ' . ($raw // '');
      return;
    }
    UnifiProtectNGDevice_ApplyDevice($hash, $json) if (ref($json) eq 'HASH');
    $cb->() if ($cb);
  });
  return undef;
}

sub UnifiProtectNGDevice_Set {
  my ($hash, $name, $cmd, @args) = @_;
  my $m = $hash->{MODELKEY} // '';
  my @l = ('patch');

  if ($m eq 'camera') {
    push @l, ('micVolume:slider,0,1,100', 'videoMode:' . join(',', @UPNG_VIDEO_MODES), 'hdr:auto,on,off', 'statusLed:on,off',
              'smartDetectObjectTypes', 'name', 'ptzGoto', 'ptzPatrolStart', 'ptzPatrolStop:noArg', 'snapshot', 'snapshotHQ:noArg');
  } elsif ($m eq 'light') {
    push @l, ('ledLevel:slider,1,1,6', 'pirSensitivity:slider,0,1,100', 'pirDuration', 'indicator:on,off', 'forceOn:on,off', 'mode:always,motion,off', 'name');
  } elsif ($m =~ /^(sensor|chime|viewer)$/) {
    push @l, 'name';
  }
  my $list = join(' ', @l);
  return "Unknown argument $cmd, choose one of $list" if (!grep { (split(/:/, $_))[0] eq $cmd } @l);

  my $arg = join(' ', @args);

  if ($cmd eq 'patch') {                       # generic: any JSON body of the official API's PATCH endpoint
    my $j = eval { decode_json($arg) };
    return 'patch needs a JSON object, e.g. set ' . $name . ' patch {"name":"Garage"}' if (ref($j) ne 'HASH');
    return UnifiProtectNGDevice_Patch($hash, $j, 'patch');
  }
  if ($cmd eq 'name') {
    return 'name needs a value' if ($arg eq '');
    return UnifiProtectNGDevice_Patch($hash, { name => $arg }, $cmd);
  }
  if ($cmd eq 'micVolume') {
    return 'micVolume: 0-100' if ($arg !~ /^\d+$/ || $arg > 100);
    return UnifiProtectNGDevice_Patch($hash, { micVolume => $arg + 0 }, $cmd);
  }
  if ($cmd eq 'videoMode') {
    return 'videoMode: ' . join('|', @UPNG_VIDEO_MODES) if (!grep { $_ eq $arg } @UPNG_VIDEO_MODES);
    return UnifiProtectNGDevice_Patch($hash, { videoMode => $arg }, $cmd);
  }
  if ($cmd eq 'hdr') {
    return 'hdr: auto|on|off' if ($arg !~ /^(auto|on|off)$/);
    return UnifiProtectNGDevice_Patch($hash, { hdrType => $arg }, $cmd);
  }
  if ($cmd eq 'statusLed') {
    return 'statusLed: on|off' if ($arg !~ /^(on|off)$/);
    return UnifiProtectNGDevice_Patch($hash, { ledSettings => { isEnabled => ($arg eq 'on' ? JSON::true : JSON::false) } }, $cmd);
  }
  if ($cmd eq 'smartDetectObjectTypes') {
    my @t = grep { $_ ne '' } split(/[ ,]+/, $arg);
    foreach my $t (@t) { return "unknown type $t, allowed: " . join(',', @UPNG_OBJECT_TYPES) if (!grep { $_ eq $t } @UPNG_OBJECT_TYPES); }
    return UnifiProtectNGDevice_Patch($hash, { smartDetectSettings => { objectTypes => \@t } }, $cmd);
  }
  if ($cmd eq 'ledLevel' || $cmd eq 'pirSensitivity' || $cmd eq 'pirDuration') {
    return "$cmd needs a number" if ($arg !~ /^\d+$/);
    return UnifiProtectNGDevice_Patch($hash, { lightDeviceSettings => { $cmd => $arg + 0 } }, $cmd);
  }
  if ($cmd eq 'indicator') {
    return 'indicator: on|off' if ($arg !~ /^(on|off)$/);
    return UnifiProtectNGDevice_Patch($hash, { lightDeviceSettings => { isIndicatorEnabled => ($arg eq 'on' ? JSON::true : JSON::false) } }, $cmd);
  }
  if ($cmd eq 'forceOn') {
    return 'forceOn: on|off' if ($arg !~ /^(on|off)$/);
    return UnifiProtectNGDevice_Patch($hash, { isLightForceEnabled => ($arg eq 'on' ? JSON::true : JSON::false) }, $cmd);
  }
  if ($cmd eq 'mode') {
    return 'mode: always|motion|off' if ($arg !~ /^(always|motion|off)$/);
    return UnifiProtectNGDevice_Patch($hash, { lightModeSettings => { mode => $arg } }, $cmd);
  }
  if ($cmd eq 'ptzGoto' || $cmd eq 'ptzPatrolStart') {
    return "$cmd needs a slot number" if ($arg !~ /^-?\d+$/);
    my $io = $hash->{IODev} or return 'no IODev';
    my $p = $cmd eq 'ptzGoto' ? "goto/$arg" : "patrol/start/$arg";
    return UnifiProtectNG_Api($io, 'POST', "/v1/cameras/$hash->{PROTECTID}/ptz/$p", undef, sub {
      my ($h, $json, $raw, $code, $err) = @_;
      Log3 $name, 2, "$name: $cmd failed: " . ($err // "HTTP $code") if ($err || $code >= 400);
    });
  }
  if ($cmd eq 'ptzPatrolStop') {
    my $io = $hash->{IODev} or return 'no IODev';
    return UnifiProtectNG_Api($io, 'POST', "/v1/cameras/$hash->{PROTECTID}/ptz/patrol/stop", undef, sub {
      my ($h, $json, $raw, $code, $err) = @_;
      Log3 $name, 2, "$name: $cmd failed: " . ($err // "HTTP $code") if ($err || $code >= 400);
    });
  }
  if ($cmd eq 'snapshot' || $cmd eq 'snapshotHQ') {
    my $io = $hash->{IODev} or return 'no IODev';
    my $dir = AttrVal($name, 'snapshotDir', '/tmp');
    my $file = $arg ne '' && $cmd eq 'snapshot' ? $arg : "$name.jpg";
    $file = "$dir/$file" if ($file !~ m{^/});
    my $q = $cmd eq 'snapshotHQ' ? '?highQuality=true' : '';
    return UnifiProtectNG_Api($io, 'GET', "/v1/cameras/$hash->{PROTECTID}/snapshot$q", undef, sub {
      my ($h, $json, $raw, $code, $err) = @_;
      if ($err || $code != 200 || !defined $raw || length($raw) < 100) {
        Log3 $name, 2, "$name: snapshot failed: " . ($err // "HTTP $code");
        return;
      }
      if (!open(my $fh, '>:raw', $file)) { Log3 $name, 2, "$name: cannot write $file: $!"; return; }
      else { print $fh $raw; close($fh); }
      readingsBeginUpdate($hash);
      readingsBulkUpdate($hash, 'snapshotFile', $file);
      readingsBulkUpdate($hash, 'snapshotTime', strftime('%Y-%m-%d %H:%M:%S', localtime));
      readingsEndUpdate($hash, 1);
      DoTrigger($name, "snapshot: $file");
    }, { raw => 1 });
  }
  return undef;
}

sub UnifiProtectNGDevice_Get {
  my ($hash, $name, $cmd, @args) = @_;
  my $m = $hash->{MODELKEY} // '';
  my $list = 'raw:noArg';
  $list .= ' rtspsStream:noArg' if ($m eq 'camera');

  if ($cmd eq 'raw') {
    return $hash->{helper}{api} ? JSON->new->canonical->pretty->encode($hash->{helper}{api}) : 'no data yet';
  }
  if ($cmd eq 'rtspsStream' && $m eq 'camera') {
    my $io = $hash->{IODev} or return 'no IODev';
    # synchronous result is not possible: the answer is stored in the reading rtspsUrl
    my $get = sub {
      UnifiProtectNG_Api($io, 'GET', "/v1/cameras/$hash->{PROTECTID}/rtsps-stream", undef, sub {
        my ($h, $json, $raw, $code, $err) = @_;
        if (!$err && $code == 200 && ref($json) eq 'HASH' && %$json) {
          readingsBeginUpdate($hash);
          readingsBulkUpdate($hash, "rtspsUrl_$_", $json->{$_}) for grep { defined $json->{$_} && !ref($json->{$_}) } sort keys %$json;
          readingsEndUpdate($hash, 1);
        } elsif ($code == 404 || (ref($json) eq 'HASH' && !%$json)) {
          UnifiProtectNG_Api($io, 'POST', "/v1/cameras/$hash->{PROTECTID}/rtsps-stream", { qualities => ['high'] }, sub {
            my ($h2, $j2, $r2, $c2, $e2) = @_;
            if (!$e2 && ref($j2) eq 'HASH') {
              readingsBeginUpdate($hash);
              readingsBulkUpdate($hash, "rtspsUrl_$_", $j2->{$_}) for grep { defined $j2->{$_} && !ref($j2->{$_}) } sort keys %$j2;
              readingsEndUpdate($hash, 1);
            }
          });
        }
      });
    };
    $get->();
    return "requested, see the readings rtspsUrl_* in a few seconds";
  }
  return "Unknown argument $cmd, choose one of $list";
}

sub UnifiProtectNGDevice_Attr {
  my ($cmd, $name, $attrName, $attrVal) = @_;
  if ($attrName eq 'eventResetTime' && $cmd eq 'set' && $attrVal !~ /^\d+$/) {
    return 'eventResetTime must be a number of seconds (0 = off)';
  }
  return undef;
}

1;

=pod
=item device
=item summary    Camera, sensor, light, chime or viewer of a UniFi Protect console (via UnifiProtectNG)
=item summary_DE Kamera, Sensor, Licht, Gong oder Viewer einer UniFi-Protect-Konsole (&uuml;ber UnifiProtectNG)
=begin html

<a name="UnifiProtectNGDevice"></a>
<h3>UnifiProtectNGDevice</h3>
<ul>
  Logical device created automatically by <a href="#UnifiProtectNG">UnifiProtectNG</a>. All data the console reports is available as readings
  (nested values are flattened, e.g. <code>ledSettings_isEnabled</code>); frequently used ones have short names
  (<code>statusLed</code>, <code>batteryPercentage</code>, <code>temperature</code>, <code>humidity</code>, ...).
  <br><br>
  <b>Event readings</b> (real time): <code>motion</code>, <code>smartDetected</code> (on/off), <code>smartDetect_zone|line|loiter|audio</code>,
  <code>smartDetect_person|vehicle|animal|package|licensePlate|face</code>, <code>lastSmartDetect</code>, <code>lastSmartDetectTypes</code>,
  <code>ring</code>, <code>contact</code> (open/closed), <code>alarm</code>, <code>leak</code>, <code>tamper</code>, <code>batteryLow</code>,
  <code>lastEvent</code>, <code>lastEventTime</code>. Unknown future event types appear as <code>event_&lt;type&gt;</code>.
  <br><br>
  <a name="UnifiProtectNGDeviceset"></a>
  <b>Set</b>
  <ul>
    <li>camera: micVolume, videoMode, hdr, statusLed, smartDetectObjectTypes, name, ptzGoto, ptzPatrolStart, ptzPatrolStop, snapshot [file], snapshotHQ</li>
    <li>light: ledLevel, pirSensitivity, pirDuration, indicator, forceOn, mode, name</li>
    <li>sensor, chime, viewer: name</li>
    <li>all: <code>patch {json}</code> sends any JSON body to the official API's PATCH endpoint of the device</li>
  </ul>
  <a name="UnifiProtectNGDeviceget"></a>
  <b>Get</b>
  <ul>
    <li>raw: last data received from the console</li>
    <li>rtspsStream (camera): creates/reads the RTSPS stream URLs (readings <code>rtspsUrl_*</code>)</li>
  </ul>
  <a name="UnifiProtectNGDeviceattr"></a>
  <b>Attributes</b>
  <ul>
    <li>snapshotDir: directory for snapshots (default /tmp)</li>
    <li>eventResetTime: seconds after which a running event is reset to off if its end event got lost (default 300, 0 = never)</li>
    <li>liveView 1|0: show a live picture (snapshot refreshed every liveInterval ms) in the camera's detail view (default 1)</li>
    <li>liveWidth: picture width in pixels (default 640), liveInterval: refresh time in ms (default 1000, minimum 200)</li>
    <li>liveInSummary 1|0: also show the live picture in room overviews (default 0)</li>
  </ul>
</ul>

=end html
=cut
