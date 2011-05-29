use Irssi;
use Irssi::TextUI;
use strict;
use XML::Atom::Client;
use POSIX;
use Encode;
use vars qw($VERSION %IRSSI);
 
$VERSION="1.0";
 
%IRSSI=(
    authors => "Matti Hiljanen",
    name => "Gmail Count",
    description => "List the number of unread messages in your Gmail Inbox",
    license => "Public Domain",
);
 
my ($count,$pcount);
my $forked;
my %lastread;
 
sub count {
    my $api=XML::Atom::Client->new;
    my ($l,$p,$f) = (Irssi::settings_get_str('gmail_user'), Irssi::settings_get_str('gmail_pass'), 
            Irssi::settings_get_str('gmail_feed'));
    return -2 if ($l eq "" || $p eq "");
 
    $api->username($l);
    $api->password($p);
 
    my $feed=$api->getFeed($f);
 
    if($feed) {
        if($feed->as_xml =~ /<fullcount>(.*?)<\/fullcount>/g) {
            my @r = int($1);
            foreach ($feed->entries) {
                my $a = $_->author->name;
                my $t = $_->title;
                my $s = $_->summary;
                $a =~ s/\t/ /g; $t =~ s/\t/ /g; $s =~ s/\t/ /g;
                my $str = "$a\t$t\t$s";
                my $encoding;
                eval {
                    require I18N::Langinfo;
                    $encoding = lc(I18N::Langinfo::langinfo(I18N::Langinfo::CODESET()));
                };
                if ($encoding && $encoding !~ /^utf-?8$/i) {
                    Encode::from_to($str, "utf8", $encoding);
                }
                push @r, $str;
            }
            return @r;
        } else {
            return -1;
        }
    } else {
      return -1;
    }
}
 
sub update {
    if ($forked) {
        Irssi::print("GMail.pl update skipped, previous update not yet finished");
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
        my @ret;
        eval {
            local $SIG{'__WARN__'} = sub { die "@_" };
            @ret = count();
        };
        if ($@) {
            print $wh "-3\n$@\n";
        } else {
            print ($wh join "\n", @ret);
        }
        close $rh;
        close $wh;
        POSIX::_exit(1);
    }
}

sub awp {
    if (Irssi::settings_get_bool('gmail_show_message') 
            && Irssi::active_server() && !Irssi::active_server()->{usermode_away}) {
        my ($a,$t,$s) = split("\t",shift,3);
        Irssi::active_win->printformat(MSGLEVEL_CLIENTCRAP, 'new_gmail_crap', $a,$t,
                Irssi::settings_get_bool('gmail_show_summary') ? $s : undef);
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

    $pcount = $count unless ($count < 0);
    $count = shift @rows;
    
    if (Irssi::settings_get_bool('gmail_debug')) { 
        Irssi::print("Gmail.pl update() finished, status is $count");
    }

    my $i = 0;
    my %nlr;
    my @tonotify;
    if ($count > 0) {
        foreach (@rows) {
            push @tonotify, @rows[$i] unless $lastread{@rows[$i]};
            $nlr{@rows[$i]} = 1;
            $i++;
        }

        if (@tonotify < 5) {
          foreach (@tonotify) {
            awp $_;
          }
        }
    }

    if ($count >= 0) {
      %lastread = %nlr;
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
    } elsif ($count > 0) {
        if ($count > $pcount) {
            $item->default_handler($get_size_only, "{sb Mail: {nick $count}}", undef, 1);
        } else {
            $item->default_handler($get_size_only, "{sb Mail: $count}", undef, 1);
        }
    } elsif ($count == -2) {
        $item->default_handler($get_size_only, "{sb Mail: {nick not configured}}", undef, 1);
    } else {
        $item->default_handler($get_size_only, "{sb Mail: {nick update error}}", undef, 1);
    }
}
 
Irssi::statusbar_item_register("mail", undef, "mail");
Irssi::settings_add_str('gmail', 'gmail_user', '');
Irssi::settings_add_str('gmail', 'gmail_pass', '');
Irssi::settings_add_str('gmail', 'gmail_feed', 'https://mail.google.com/mail/feed/atom');
Irssi::settings_add_bool('gmail', 'gmail_show_message', 1);
Irssi::settings_add_bool('gmail', 'gmail_show_summary', 1);
Irssi::settings_add_bool('gmail', 'gmail_debug', 0);

Irssi::theme_register(
        [
        'new_gmail_crap',
        '{line_start}%_new%_ %BG%RM%Ya%Bi%Gl%N from %c$0%N with subject %c$1%N %K$2%N'
        ]);

Irssi::print("GMail.pl loaded.");
Irssi::print("Remember to set your username and password (gmail_user and gmail_pass) " 
        . "and add \"mail\" statusbar item to your statusbar.") unless (Irssi::settings_get_str('gmail_user'));
 
update();
Irssi::timeout_add(60*1000, "update", undef);
