use Irssi;
use Irssi::TextUI;
use strict;
use XML::Atom::Client;
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
    my ($l,$p) = (Irssi::settings_get_str('gmail_user'), Irssi::settings_get_str('gmail_pass'));
    return 0 if ($l eq "" || $p eq "");
 
    $api->username($l);
    $api->password($p);
 
    my $feed=$api->getFeed("https://mail.google.com/mail/feed/atom");
 
    if($feed) {
        if($feed->as_xml =~ /<fullcount>(.*)<\/fullcount>/g) {
            return int($1);
        } else {
            return 0;
        }
    } else {
      return 0;
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
        eval {
            local $SIG{'__WARN__'} = sub { die "@_" };
            print $wh count() . "\n";
        };
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

    $count = $rows[0];

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
 
update();
Irssi::timeout_add(60*1000, "update", undef);
