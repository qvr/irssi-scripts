#
# based on tommie's anotherway script
# tommie's part GPLv2, my part public domain
#

use strict;
use vars qw($VERSION %IRSSI);
$VERSION = "2009051301";
%IRSSI = (
    authors     => "Stefan 'tommie' Tomanek, Matti Hiljanen",
    contact     => "stefan\@pico.ruhr.de",
    name        => "anotherway",
    description => "Another auto away script with screen detach/attach integration",
    license     => "GPLv2, Public Domain",
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

sub go_away {
    Irssi::print "%R>>%n Going away..." if Irssi::settings_get_bool("anotherway_debug");
    &remove_timer;
    my $reason = Irssi::settings_get_str("anotherway_reason");
    my @servers = Irssi::servers();
    return unless @servers;
    Irssi::signal_remove($_ , "reset_timer") foreach (@reset_signals);
    $servers[0]->command('AWAY '.$reason);
    Irssi::signal_add($_ , "come_back") foreach (@exit_signals);
}

sub come_back {
    Irssi::print "%R>>%n Coming back..." if Irssi::settings_get_bool("anotherway_debug");
    foreach (Irssi::servers()) {
        if ($_->{usermode_away}) {
            $_->command('AWAY');
            last;
        }
    }
    Irssi::signal_remove($_ , "come_back") foreach (@exit_signals);
    Irssi::signal_remove($_ , "reset_timer") foreach (@reset_signals);
    Irssi::signal_add($_, "reset_timer") foreach (@reset_signals);
}

sub reset_timer {
    if (!$timer) {
        Irssi::print "no timer set, checking if we're already away" 
            if Irssi::settings_get_bool("anotherway_debug");
        my $away = 0;
        foreach (Irssi::servers()) {
           if ($_->{usermode_away}) {
               $away = 1;
               last;
           }
        }

        &register_timer unless $away;
        return;
    }
    Irssi::print "%R>>%n TIMER RESET" if Irssi::settings_get_bool("anotherway_debug");
    &remove_timer;
    &register_timer;
}

sub screen_check {
    if (!defined($ENV{STY}) || !$screen_socket_path) {
        Irssi::print ("Not running under screen") if Irssi::settings_get_bool("anotherway_debug");
        $attached = -1;
        return;
    }

    my $socket = $screen_socket_path . "/" . $ENV{'STY'};
    return unless ( -e $socket );

    my $cur_att = &screen_attached($socket);

    if ($cur_att != $attached) {
        Irssi::print ("screen status change") if Irssi::settings_get_bool("anotherway_debug");
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
    if ($timer) {
        Irssi::print "%R>>%n ".$IRSSI{name}." tried to register double timer";
        return;
    }
    my $timeout;
    if ($attached == 0) {
        $timeout = Irssi::settings_get_int("anotherway_detached_timeout");
    } else {
        $timeout = Irssi::settings_get_int("anotherway_timeout");
    }
    Irssi::print "registering away timer, timeout $timeout" if Irssi::settings_get_bool("anotherway_debug");
    $timer = Irssi::timeout_add_once($timeout*1000, "go_away", undef);
}

sub remove_timer {
    Irssi::print "timer removed" if Irssi::settings_get_bool("anotherway_debug");
    Irssi::timeout_remove($timer);
    $timer = undef;
}

Irssi::settings_add_str($IRSSI{name}, 'anotherway_reason', 'a-nother-way');
Irssi::settings_add_int($IRSSI{name}, 'anotherway_timeout', 600);
Irssi::settings_add_int($IRSSI{name}, 'anotherway_detached_timeout', 120);
Irssi::settings_add_bool($IRSSI{name}, 'anotherway_debug', 0);

Irssi::signal_add($_, "reset_timer") foreach (@reset_signals);
Irssi::timeout_add(15*1000, "screen_check", undef);

print CLIENTCRAP '%B>>%n '.$IRSSI{name}.' '.$VERSION.' loaded';
Irssi::print "No screen socket path found, detach detection will not work" unless $screen_socket_path;
