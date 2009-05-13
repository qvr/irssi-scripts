use strict;
use vars qw($VERSION %IRSSI);
$VERSION = "2009051301";
%IRSSI = (
    authors     => "Stefan 'tommie' Tomanek",
    contact     => "stefan\@pico.ruhr.de",
    name        => "anotherway",
    description => "Another auto away script",
    license     => "GPLv2",
    changed     => "$VERSION",
);
use Irssi;
use vars qw($timer @exit_signals @reset_signals $screen_socket_path $attached);

@reset_signals = ('message own_public', 'message own_private', 'window changed');
@exit_signals = ('message own_public', 'message own_private');
$attached = -1;

my $screen_ls = `LC_ALL="C" screen -ls`;

if ($screen_ls !~ /^No Sockets found/s) {
    $screen_ls =~ /^.+\d+ Sockets? in ([^\n]+)\.\n.+$/s;
    $screen_socket_path = $1;
} else {
    $screen_ls =~ /^No Sockets found in ([^\n]+)\.\n.+$/s;
    $screen_socket_path = $1;
}
Irssi::print "Screen socket path: $screen_socket_path";
    

sub go_away {
    Irssi::print "%R>>%n Going away...";
    Irssi::timeout_remove($timer);
    $timer = undef;
    my $reason = Irssi::settings_get_str("anotherway_reason");
    my @servers = Irssi::servers();
    return unless @servers;
    Irssi::signal_remove($_ , "reset_timer") foreach (@reset_signals);
    $servers[0]->command('AWAY '.$reason);
    Irssi::signal_add($_ , "come_back") foreach (@exit_signals);
}

sub come_back {
    Irssi::print "%R>>%n Coming back...";
    foreach (Irssi::servers()) {
        if ($_->{usermode_away}) {
            $_->command('AWAY');
            last;
        }
    }
    &register_timer;
    Irssi::signal_add($_, "reset_timer") foreach (@reset_signals);
}

sub reset_timer {
    if (!$timer) {
        Irssi::print "no timer set, checking if we're already away";
        my $away = 0;
        foreach (Irssi::servers()) {
           if ($_->{usermode_away}) {
               $away = 1;
               last;
           }
        }

        if (!$away) {
            Irssi::print "not away, setting timer";
            &register_timer;
        }
        return;
    }
    Irssi::print "%R>>%n RESET";
    Irssi::timeout_remove($timer);
    my $timeout;
    if ($attached == 0) {
        $timeout = Irssi::settings_get_int("anotherway_detached_timeout");
        Irssi::print("timeout is in detached mode");
    } else {
        $timeout = Irssi::settings_get_int("anotherway_timeout");
        Irssi::print("timeout is in attached mode");
    }
    $timer = Irssi::timeout_add($timeout*1000, "go_away", undef);
}

sub screen_check {
    if (!defined($ENV{STY})) {
        Irssi::print ("Not running under screen");
        $attached = -1;
        return;
    }

    my $socket = $screen_socket_path . "/" . $ENV{'STY'};
    my $cur_att = &screen_attached($socket);

    if ($cur_att) {
        Irssi::print ("Under screen and currently attached");
    } else {
        Irssi::print ("Under screen and currently detached");
    }

    if ($cur_att != $attached) {
        Irssi::print ("screen status change");
        $attached = $cur_att;
        &reset_timer();
    }
}

sub screen_attached {
    my $socket = shift;

    if (((stat($socket))[2] & 00100) == 0) { # detached
        return 0;
    } else {
        return 1;
    }
}

sub register_timer {
    Irssi::print "registering away timer";
    $timer = Irssi::timeout_add(Irssi::settings_get_int("anotherway_timeout")*1000, "go_away", undef);
}

Irssi::settings_add_str($IRSSI{name}, 'anotherway_reason', 'a-nother-way');
Irssi::settings_add_int($IRSSI{name}, 'anotherway_timeout', 300);
Irssi::settings_add_int($IRSSI{name}, 'anotherway_detached_timeout', 60);

&register_timer;
Irssi::signal_add($_, "reset_timer") foreach (@reset_signals);
Irssi::timeout_add(10*1000, "screen_check", undef);

print CLIENTCRAP '%B>>%n '.$IRSSI{name}.' '.$VERSION.' loaded';
