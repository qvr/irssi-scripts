use Irssi;
use Irssi::TextUI;
use strict;
use XML::Atom::Client;
use POSIX;
use vars qw($VERSION %IRSSI);
 
$VERSION="1.0";
 
%IRSSI=(
    authors => "Matti Hiljanen",
    name => "Gmail Count",
    description => "List the number of unread messages in your Gmail Inbox",
    license => "Public Domain",
);
 
my $count;
my $forked;
 
sub count {
    my $api=XML::Atom::Client->new;
    my ($l,$p,$f) = (Irssi::settings_get_str('gmail_user'), Irssi::settings_get_str('gmail_pass'), 
            Irssi::settings_get_str('gmail_feed'));
    return -2 if ($l eq "" || $p eq "");
 
    $api->username($l);
    $api->password($p);
 
    my $feed=$api->getFeed($f);
 
    if($feed) {
        if($feed->as_xml =~ /<fullcount>(.*)<\/fullcount>/g) {
            return int($1);
        } else {
            return -1;
        }
    } else {
      return -1;
    }
}
 
sub update {
    if ($forked) {
        Irssi::print("gmail update failed, already forked");
        return;
    }
    
    my ($rh,$wh);
    pipe $rh, $wh;
    $forked = 1;
    my $pid = fork();

    unless (defined($pid)) {
        Irssi::print("Can't fork for gmail update() - abort");
        close $rh;
        close $wh;
        return;
    }

    if ($pid > 0) {
        close $wh;
        Irssi::pidwait_add($pid);
        my $target = {fh => $$rh, tag => undef};
        $target->{tag} = Irssi::input_add(fileno($rh), INPUT_READ, \&read_pipe, $target);
    } else {
        my $ret = -3;
        eval {
            local $SIG{'__WARN__'} = sub { die "@_" };
            $ret = count();
        };
        if ($@) {
            my $err = $@;
            chomp $err;
            $err =~ s/\n/-/g;
            print $wh "0\nERR $err\n";
        } else {
            if ($ret >= 0) {
                print $wh $ret . "\nOK\n";
            } elsif ($ret == -1) {
                print $wh "0\nERR getting feed failed\n";
            } elsif ($ret == -2) {
                print $wh "0\nERR l/p not set, update skipped\n";
            } else {
                print $wh "0\nERR unknown error\n";
            }
        }
        close $rh;
        close $wh;
        POSIX::_exit(1);
    }
}

sub read_pipe {
    my $target = shift;
    my $rh = $target->{fh};

    my @rows = ();
    while (<$rh>) {
        chomp;
        push @rows, $_;
    }

    close($target->{fh});
    Irssi::input_remove($target->{tag});
    $forked = 0;

    my $status = pop @rows;

    $count = $rows[0];
    
    if (Irssi::settings_get_bool('gmail_debug')) { 
        Irssi::print("Gmail feed updated, status is '$status', count is $count");
    }

    refresh();
}
 
sub refresh {
    Irssi::statusbar_items_redraw("mail");
}
 
sub mail {
    my ($item, $get_size_only)=@_;
 
    if($count == 0) {
        $item->default_handler($get_size_only, "", undef, 1);
    } else {
        $item->default_handler($get_size_only, "{sb Mail: $count}", undef, 1);
    }
}
 
Irssi::statusbar_item_register("mail", undef, "mail");
Irssi::settings_add_str('gmail', 'gmail_user', '');
Irssi::settings_add_str('gmail', 'gmail_pass', '');
Irssi::settings_add_str('gmail', 'gmail_feed', 'https://mail.google.com/mail/feed/atom');
Irssi::settings_add_bool('gmail', 'gmail_debug', 0);

Irssi::print("GMail.pl loaded. Remember to set your username and password (gmail_user and gmail_pass) " 
        . "and add \"mail\" statusbar item to your statusbar. "
        . "You can enable debugging with /toggle gmail_debug");
 
update();
Irssi::timeout_add(60*1000, "update", undef);
