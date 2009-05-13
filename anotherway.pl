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
use vars qw($timer @exit_signals @reset_signals $attached);

@reset_signals = ('message own_public', 'message own_private', 'window changed');
@exit_signals = ('message own_public', 'message own_private');
$attached = -1;

sub go_away {
    Irssi::print "%R>>%n Going away...$timer";
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
        $_->command('AWAY') if $_->{usermode_away};
        last;
    }
}

sub reset_timer {
    Irssi::print "%R>>%n RESET";
    Irssi::signal_remove($_ , "reset_timer") foreach (@reset_signals);
    Irssi::timeout_remove($timer);
    my $timeout;
    if ($attached == 0) {
        $timeout = Irssi::settings_get_int("anotherway_detached_timeout");
    } else {
        $timeout = Irssi::settings_get_int("anotherway_timeout");
    }
    $timer = Irssi::timeout_add($timeout*1000, "go_away", undef);
    Irssi::signal_add($_, "reset_timer") foreach (@reset_signals);
}

sub screen_check {
    if (!defined($ENV{STY})) {
        Irssi::print ("Not running under screen");
        $attached = -1;
        return;
    }

    my $socket = "/var/run/screen/S-" . $ENV{'USER'} . "/" . $ENV{'STY'};
    my $cur_att = &screen_attached($socket);

    if ($cur_att) {
        Irssi::print ("Under screen and currently attached");
    } else {
        Irssi::print ("Under screen and currently detached");
    }

    if ($cur_att != $attached) {
        Irssi::print ("screen status change");
        &reset_timer();
        $attached = $cur_att;
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

Irssi::settings_add_str($IRSSI{name}, 'anotherway_reason', 'a-nother-way');
Irssi::settings_add_int($IRSSI{name}, 'anotherway_timeout', 300);
Irssi::settings_add_int($IRSSI{name}, 'anotherway_detached_timeout', 60);

{
    Irssi::signal_add($_, "reset_timer") foreach (@reset_signals);
    reset_timer();
}

Irssi::timeout_add(10*1000, "screen_check", undef);

print CLIENTCRAP '%B>>%n '.$IRSSI{name}.' '.$VERSION.' loaded';
