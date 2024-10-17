use strict; use warnings;

use Irssi;
use POSIX;
use Encode;
use LWP::UserAgent;
use LWP::Protocol::https;
use URI;
use vars qw($VERSION %IRSSI);

$VERSION = "18";
%IRSSI   = (
    authors     => "Lauri 'murgo' Härsilä, Matti 'qvr' Hiljanen",
    contact     => "matti\@hiljanen.com",
    name        => "IrssiNotifier",
    description => "Send notifications about irssi highlights to pushover",
    license     => "Apache License, version 2.0",
    url         => "https://github.com/qvr/irssi-scripts",
    changed     => "2024-10-17"
);

my $lastMsg;
my $lastServer;
my $lastNick;
my $lastTarget;
my $lastWindow;
my $lastKeyboardActivity = time;
my $lastSent = 0;
my $forked;
my $lastDcc = 0;
my $notifications_sent = 0;
my @delayQueue = ();

my $screen_socket_path;

sub private {
    my ( $server, $msg, $nick, $address ) = @_;
    $lastServer  = $server;
    $lastMsg     = $msg;
    $lastNick    = $nick;
    $lastTarget  = "!PRIVATE";
    $lastWindow  = $nick;
    $lastDcc = 0;
}

sub joined {
    my ( $server, $target, $nick, $address ) = @_;
    $lastServer  = $server;
    $lastMsg     = "joined";
    $lastNick    = $nick;
    $lastTarget  = $target;
    $lastWindow  = $target;
    $lastDcc = 0;
}

sub public {
    my ( $server, $msg, $nick, $address, $target ) = @_;
    $lastServer  = $server;
    $lastMsg     = $msg;
    $lastNick    = $nick;
    $lastTarget  = $target;
    $lastWindow  = $target;
    $lastDcc = 0;
}

sub dcc {
    my ( $dcc, $msg ) = @_;
    $lastServer  = $dcc->{server};
    $lastMsg     = $msg;
    $lastNick    = $dcc->{nick};
    $lastTarget  = "!PRIVATE";
    $lastWindow  = $dcc->{target};
    $lastDcc = 1;
}

sub print_text {
    my ($dest, $text, $stripped) = @_;

    if (!defined $lastMsg || index($text, $lastMsg) == -1)
    {
        # text doesn't contain the message, so printed text is about something else and notification doesn't need to be sent
        return;
    }

    if (should_send_notification($dest))
    {
        send_notification();
    }
}

sub should_send_notification {
    my $dest = @_ ? shift : $_;

    my $opt = MSGLEVEL_HILIGHT | MSGLEVEL_MSGS;
    if (!$lastDcc && (!($dest->{level} & $opt) || ($dest->{level} & MSGLEVEL_NOHILIGHT))) {
        return 0; # not a hilight and not a dcc message
    }

    if (!are_settings_valid()) {
        return 0; # invalid settings
    }

    if (Irssi::settings_get_bool("irssinotifier_away_only") && !$lastServer->{usermode_away}) {
        return 0; # away only
    }

    if ($lastDcc && !Irssi::settings_get_bool("irssinotifier_enable_dcc")) {
        return 0; # dcc is not enabled
    }

    if (Irssi::settings_get_bool('irssinotifier_screen_detached_only') && screen_attached()) {
        return 0; # screen attached
    }

    if (Irssi::settings_get_bool("irssinotifier_ignore_active_window") && $dest->{window}->{refnum} == Irssi::active_win()->{refnum}) {
        return 0; # ignore active window
    }

    my $ignored_servers_string = Irssi::settings_get_str("irssinotifier_ignored_servers");
    if ($ignored_servers_string) {
        my @ignored_servers = split(/ /, $ignored_servers_string);
        my $server;

        foreach $server (@ignored_servers) {
            if (lc($server) eq lc($lastServer->{tag})) {
                return 0; # ignored server
            }
        }
    }

    my $ignored_channels_string = Irssi::settings_get_str("irssinotifier_ignored_channels");
    if ($ignored_channels_string) {
        my @ignored_channels = split(/ /, $ignored_channels_string);
        my $channel;

        foreach $channel (@ignored_channels) {
            if (lc($channel) eq lc($lastWindow)) {
                return 0; # ignored channel
            }
        }
    }

    # Ignore any highlights from given nicks
    my $ignored_nicks_string = Irssi::settings_get_str("irssinotifier_ignored_nicks");
    if ($ignored_nicks_string ne '') {
        my @ignored_nicks = split(/ /, $ignored_nicks_string);
        if (grep { lc($_) eq lc($lastNick) } @ignored_nicks) {
            return 0; # Ignored nick
        }
    }

    # Ignore any highlights that match any specified patterns
    my $ignored_highlight_pattern_string = Irssi::settings_get_str("irssinotifier_ignored_highlight_patterns");
    if ($ignored_highlight_pattern_string ne '') {
        my @ignored_patterns = split(/ /, $ignored_highlight_pattern_string);
        if (grep { $lastMsg =~ /$_/i } @ignored_patterns) {
            return 0; # Ignored pattern
        }
    }

    # If specified, require a pattern to be matched before highlighting public messages
    my $required_public_highlight_pattern_string = Irssi::settings_get_str("irssinotifier_required_public_highlight_patterns");
    if ($required_public_highlight_pattern_string ne '' && ($dest->{level} & MSGLEVEL_PUBLIC)) {
        my @required_patterns = split(/ /, $required_public_highlight_pattern_string);
        if (!(grep { $lastMsg =~ /$_/i } @required_patterns)) {
            return 0; # Required pattern not matched
        }
    }

    my $timeout = Irssi::settings_get_int('irssinotifier_require_idle_seconds');
    if ($timeout > 0 && (time - $lastKeyboardActivity) <= $timeout && screen_attached()) {
        return 0; # not enough idle seconds
    }

    return 1;
}

sub screen_attached {
    if (!$screen_socket_path || !defined($ENV{STY})) {
        return 1;
    }
    my $socket = $screen_socket_path . "/" . $ENV{'STY'};
    if (-e $socket && ((stat($socket))[2] & 00100) != 0) {
        return 1;
    }
    return 0;
}

sub send_notification {
    if ($forked) {
        if (scalar @delayQueue < 10) {
            push @delayQueue, {
                            'msg' => $lastMsg,
                            'nick' => $lastNick,
                            'target' => $lastTarget,
                            'added' => time,
                            };
        } else {
            Irssi::print("IrssiNotifier: previous send is still in progress and queue is full, skipping notification");
        }
        return 0;
    }
    send_to_api();
}

sub send_command {
    my $cmd = shift || return;
    return if ($forked); # no need to queue commands?
    send_to_api("cmd", $cmd);
}

sub send_to_api {
    my $type = shift || "notification";

    my $command;
    if ($type eq "cmd") {
        $command = shift || return;
    }

    my ($readHandle,$writeHandle);
    pipe $readHandle, $writeHandle;
    $forked = 1;
    my $pid = fork();

    unless (defined($pid)) {
        Irssi::print("IrssiNotifier: couldn't fork - abort");
        close $readHandle; close $writeHandle;
        return 0;
    }

    if ($pid > 0) {
        close $writeHandle;
        Irssi::pidwait_add($pid);
        my $target = {fh => $$readHandle, tag => undef, type => $type};
        $target->{tag} = Irssi::input_add(fileno($readHandle), INPUT_READ, \&read_pipe, $target);
    } else {
        close (STDIN); close (STDOUT); close (STDERR);
        eval {
            my $proxy     = Irssi::settings_get_str('irssinotifier_https_proxy');

            if($proxy) {
                $ENV{https_proxy} = $proxy;
            }

            my $browser = LWP::UserAgent->new;
            my $api_url;

            if ($type eq 'notification') {
                $lastMsg = Irssi::strip_codes($lastMsg);

                encode_utf();
                my $title = $lastTarget;
                my $message = $lastNick.': '.$lastMsg;

                if ($title eq '!PRIVATE') {
                    $title = $lastNick;
                    $message = $lastMsg;
                }

                my $priority = 0;
                if ((time - $lastSent) <= Irssi::settings_get_int('irssinotifier_mute_window_seconds')) {
                    $priority = -1;
                }

                $api_url = URI->new("https://api.pushover.net/1/messages.json");
                $api_url->query_form( 'token'     => Irssi::settings_get_str('irssinotifier_pushover_api_token'),
                                      'user'      => Irssi::settings_get_str('irssinotifier_pushover_user_key'),
                                      'message'   => $message,
                                      'sound'     => Irssi::settings_get_str('irssinotifier_pushover_sound'),
                                      'title'     => $title,
                                      'priority'  => $priority,
                                      'url'       => Irssi::settings_get_str('irssinotifier_pushover_url'),
                                      'url_title' => Irssi::settings_get_str('irssinotifier_pushover_url_title') );

            }

            if ($api_url) {
                my $response = $browser->post($api_url);
                if (!$response->is_success) {
                    # Something went wrong, might be network error or authorization issue. Probably no need to alert user, though.
                    print $writeHandle "0 FAIL: " . $response->status_line . "\n";
                } else {
                    print $writeHandle "1 OK\n";
                }
            } else {
                print $writeHandle "1 NOOP: unsupported type for mode\n";
            }
        }; # end eval

        if ($@) {
            print $writeHandle "-1 IrssiNotifier internal error: $@\n";
        }

        close $readHandle; close $writeHandle;
        POSIX::_exit(1);
    }
    return 1;
}

sub encode_utf {
    # encode messages to utf8 if terminal is not utf8 (irssi's recode should be on)
    my $encoding;
    eval {
        require I18N::Langinfo;
        $encoding = lc(I18N::Langinfo::langinfo(I18N::Langinfo::CODESET()));
    };
    if ($encoding && $encoding !~ /^utf-?8$/i) {
        $lastMsg    = Encode::encode_utf8($lastMsg);
        $lastNick   = Encode::encode_utf8($lastNick);
        $lastTarget = Encode::encode_utf8($lastTarget);
    }
}

sub read_pipe {
    my $target = shift;
    my $readHandle = $target->{fh};

    my $output = <$readHandle>;
    chomp($output);

    close($target->{fh});
    Irssi::input_remove($target->{tag});
    $forked = 0;

    $output =~ /^(-?\d+) (.*)$/;
    my $ret = $1;
    $output = $2;

    if ($ret < 0) {
        Irssi::print($IRSSI{name} . ": Error: send crashed: $output");
    } elsif (!$ret) {
        #Irssi::print($IRSSI{name} . ": Error: send failed: $output");
    }

    if (Irssi::settings_get_bool('irssinotifier_clear_notifications_when_viewed') && $target->{type} eq 'notification') {
        $notifications_sent++;
    }

    $lastSent = time if ($target->{type} eq 'notification');

    check_delayQueue();
}

sub are_settings_valid {
    Irssi::signal_remove( 'gui key pressed', 'event_key_pressed' );
    if (Irssi::settings_get_int('irssinotifier_require_idle_seconds') > 0) {
        Irssi::signal_add( 'gui key pressed', 'event_key_pressed' );
    }

    if (!Irssi::settings_get_str('irssinotifier_pushover_api_token')) {
        Irssi::print("IrssiNotifier: Set pushover API token to send notifications: /set irssinotifier_pushover_api_token [token]");
        return 0;
    }

    if (!Irssi::settings_get_str('irssinotifier_pushover_user_key')) {
        Irssi::print("IrssiNotifier: Set pushover user key to send notifications: /set irssinotifier_pushover_user_key [key]");
        return 0;
    }

    $notifications_sent = 0 unless (Irssi::settings_get_bool('irssinotifier_clear_notifications_when_viewed'));

    return 1;
}

sub check_delayQueue {
    if (scalar @delayQueue > 0) {
      my $item = shift @delayQueue;
      if (time - $item->{'added'} > 60) {
          check_delayQueue();
          return 0;
      } else {
          $lastMsg = $item->{'msg'};
          $lastNick = $item->{'nick'};
          $lastTarget = $item->{'target'};
          send_notification();
          return 0;
      }
    }
    return 1;
}

sub check_window_activity {
    return if (!$notifications_sent);

    my $act = 0;
    foreach (Irssi::windows()) {
        # data_level 3 means window has unseen hilight
        if ($_->{data_level} == 3) {
            $act++; last;
        }
    }

    if (!$act) {
        send_command("clearNotifications");
        $notifications_sent = 0;
    }
}

sub event_key_pressed {
    $lastKeyboardActivity = time;
}

my $screen_ls = `LC_ALL="C" screen -ls`;
if ($screen_ls !~ /^No Sockets found/s) {
    $screen_ls =~ /^.*\d+ Sockets? in ([^\n]+)\..*$/s;
    $screen_socket_path = $1;
} else {
    $screen_ls =~ /^No Sockets found in ([^\n]+)\.\n.+$/s;
    $screen_socket_path = $1;
}

Irssi::settings_add_str('irssinotifier', 'irssinotifier_https_proxy', '');
Irssi::settings_add_str('irssinotifier', 'irssinotifier_ignored_servers', '');
Irssi::settings_add_str('irssinotifier', 'irssinotifier_ignored_channels', '');
Irssi::settings_add_str('irssinotifier', 'irssinotifier_ignored_nicks', '');
Irssi::settings_add_str('irssinotifier', 'irssinotifier_ignored_highlight_patterns', '');
Irssi::settings_add_str('irssinotifier', 'irssinotifier_required_public_highlight_patterns', '');
Irssi::settings_add_str('irssinotifier', 'irssinotifier_pushover_api_token', '');
Irssi::settings_add_str('irssinotifier', 'irssinotifier_pushover_user_key', '');
Irssi::settings_add_str('irssinotifier', 'irssinotifier_pushover_sound', '');
Irssi::settings_add_str('irssinotifier', 'irssinotifier_pushover_url', '');
Irssi::settings_add_str('irssinotifier', 'irssinotifier_pushover_url_title', '');
Irssi::settings_add_bool('irssinotifier', 'irssinotifier_ignore_active_window', 0);
Irssi::settings_add_bool('irssinotifier', 'irssinotifier_away_only', 0);
Irssi::settings_add_bool('irssinotifier', 'irssinotifier_screen_detached_only', 0);
Irssi::settings_add_bool('irssinotifier', 'irssinotifier_clear_notifications_when_viewed', 0);
Irssi::settings_add_int('irssinotifier', 'irssinotifier_require_idle_seconds', 0);
Irssi::settings_add_int('irssinotifier', 'irssinotifier_mute_window_seconds', 60);
Irssi::settings_add_bool('irssinotifier', 'irssinotifier_enable_dcc', 1);

# these settings have been renamed or removed
Irssi::settings_remove('irssinotifier_ignore_server');
Irssi::settings_remove('irssinotifier_ignore_channel');
Irssi::settings_remove('irssinotifier_mode');
Irssi::settings_remove('irssinotifier_encryption_password');
Irssi::settings_remove('irssinotifier_api_token');

Irssi::signal_add('message irc action', 'public');
Irssi::signal_add('message public',     'public');
Irssi::signal_add('message private',    'private');
Irssi::signal_add('message join',       'joined');
Irssi::signal_add('message dcc',        'dcc');
Irssi::signal_add('message dcc action', 'dcc');
Irssi::signal_add('print text',         'print_text');
Irssi::signal_add('setup changed',      'are_settings_valid');
Irssi::signal_add('window changed',     'check_window_activity');
