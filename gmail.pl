{
  package Net::GmailOAuth;
  use strict;

  use base qw(Net::OAuth::Simple);

  sub new {
    my $class  = shift;
    my %params = @_;

    my $displayname = "";
    $displayname = "&xoauth_displayname=" . $params{name} if ($params{name} && length($params{name}) > 0);

    return $class->SUPER::new(
        urls   => {
          request_token_url => "https://www.google.com/accounts/OAuthGetRequestToken?scope=https://mail.google.com/mail/feed/atom/$displayname",
          authorization_url => "https://www.google.com/accounts/OAuthAuthorizeToken",
          access_token_url  => "https://www.google.com/accounts/OAuthGetAccessToken",
        },
        return_undef_on_error => 1,
        %params,
        );
  }

  sub _make_request {
    my $self    = shift;
    my $class   = shift;
    my $url     = shift;
    my $method  = uc(shift);
    my @extra   = @_;

    my $uri   = URI->new($url);
    my %query = $uri->query_form;
    $uri->query_form({});

    my $request = $class->new(
        consumer_key     => $self->consumer_key,
        consumer_secret  => $self->consumer_secret,
        request_url      => $uri,
        request_method   => $method,
        signature_method => $self->signature_method,
        protocol_version => $self->oauth_1_0a ? Net::OAuth::PROTOCOL_VERSION_1_0A : Net::OAuth::PROTOCOL_VERSION_1_0,
        timestamp        => time,
        nonce            => $self->_nonce,
        extra_params     => \%query,
        @extra,
        );
    $request->sign;
    return $self->_error("Couldn't verify request! Check OAuth parameters.")
      unless $request->verify;

    my $req;
    if ('GET' eq $method || 'PUT' eq $method) {
      my @args    = ();
      my $req_url = $url;
      my $params  = $request->to_hash;
      $req_url = URI->new($url);
      $req_url->query_form(%$params);

      $req      = HTTP::Request->new( $method => $req_url, @args);
    } else {
      $req = HTTP::Request->new($method => $uri);
      $req->header('Content-type' => 'application/atom+xml');
      $req->header('Authorization' => $request->to_authorization_header);
      $req->header('Content_Length' => '0'); # Google bug
    }
    my $response = $self->{browser}->request($req);
    return $self->_error("$method on $request failed: ".$response->status_line)
      unless ( $response->is_success );

    return $response;
  }

  1;
}

use Irssi;
use Irssi::TextUI;
use strict;
use XML::Atom::Feed;
use POSIX;
use Encode;
use vars qw($VERSION %IRSSI);

$VERSION="2.0";

%IRSSI=(
    authors => "Matti Hiljanen",
    name => "Irssi Gmail Count",
    description => "List the number of unread messages in your Gmail Inbox",
    license => "GPLv2",
);

our ($count,$pcount);
our ($forked,$authed);
our %mcache;

our $oauth_store = Irssi::get_irssi_dir . "/gmail.oauth";
our %tokens = (
  consumer_key => "anonymous",
  consumer_secret => "anonymous",
  access_token => undef,
  access_token_secret => undef,
  request_token => undef,
  request_token_secret => undef,
  request_token_timestamp => 0,
);

sub count {
    my $xml = shift;
    my $feed = XML::Atom::Feed->new(\$xml);

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

sub oauth_worker {
  my $action = shift || return 0;
  my $params = shift;
  if ($forked) {
    Irssi::print($IRSSI{name} . ": oauth_worker still busy, $action skipped");
    return;
  }

  my ($rh,$wh);
  pipe $rh, $wh;
  $forked = 1;
  my $pid = fork();

  unless (defined($pid)) {
    Irssi::print($IRSSI{name} . ": Can't fork for oauth_worker() - abort");
    close $rh;
    close $wh;
    return;
  }

  if ($pid > 0) {
    close $wh;
    Irssi::pidwait_add($pid);
    my $target = {fh => $$rh, tag => undef, action => $action};
    $target->{tag} = Irssi::input_add(fileno($rh), INPUT_READ, \&read_pipe, $target);
  } else {
    my @ret;
    eval {
      local $SIG{'__WARN__'} = sub { die "@_" };
      if ($action eq "request") {
        my $oauth = Net::GmailOAuth->new(
            name => $IRSSI{name},
            tokens => $params->{tokens},
        );

        $oauth->callback("oob");
        my $auth_url = $oauth->get_authorization_url;
        my $request_token = $oauth->request_token;
        my $request_token_secret = $oauth->request_token_secret;

        if ($auth_url) {
          print $wh "1\n$auth_url $request_token $request_token_secret\n";
        } else {
          print $wh "0\n" . $oauth->last_error . "\n";
        }
      } elsif ($action eq "access") {
        my $oauth = Net::GmailOAuth->new(
            name => $IRSSI{name},
            tokens => $params->{tokens},
        );

        my ($token,$secret) = $oauth->request_access_token(verifier => $params->{verifier});
        if ($oauth->authorized) {
          print $wh "1\n$token $secret\n";
        } else {
          print $wh "0\n" . $oauth->last_error . "\n";
        }
      } elsif ($action eq "update") {
        my $oauth = Net::GmailOAuth->new(
            tokens => $params->{tokens},
        );

        my $feed = "https://mail.google.com/mail/feed/atom/";

        my $label = Irssi::settings_get_str("gmail_feed_label");
        if ($label && length($label) > 0) {
          $feed .= $label;
        }

        my $response = $oauth->make_restricted_request($feed, 'POST');

        if ($response) {
          @ret = count($response->content);
          print ($wh join "\n", @ret);
        } else {
          my $err = $oauth->last_error;
          my $ret = -3;
          if ($err =~ /failed: (502|500)/) { # temporary error, try again
            $ret = -1;
          } elsif ($err =~ /failed: 401/) { # auth failed, revoked auth token?
            $ret = -2;
          }
          print $wh "$ret\n$err\n";
        }
      }
    };
    if ($@) {
      print $wh "-3\n" . join(' ', split('\n', $@)) . "\n"; # crash
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

  if (Irssi::settings_get_bool('gmail_debug')) {
    Irssi::print($IRSSI{name} . ": oauth_worker() finished, task: " . $target->{action} . ", status: " . $rows[0]);
  }

  if ($rows[0] == -3) {
    Irssi::print($IRSSI{name} . ": oauth_worker() crashed, output: " . $rows[1]);
    return 0;
  }

  if ($target->{action} eq "request" or $target->{action} eq "access") {
    my $ret = $rows[0];
    my $output = $rows[1];

    if ($target->{action} eq "request") {
      if ($ret) {
        $output =~ /^(\S+) (\S+) (\S+)$/;
        Irssi::print("Authorize " . $IRSSI{name} . " at the following url: " . escape($1) .
            " and then enter the verification code with /gmail verify <code>");
        $tokens{request_token} = $2;
        $tokens{request_token_secret} = $3;
        $tokens{request_token_timestamp} = time;
      }
    } elsif ($target->{action} eq "access") {
      if ($ret) {
        $output =~ /^(\S+) (\S+)$/;
        store_oauth($1,$2);
        Irssi::print($IRSSI{name} . ": OK, authorization successful");
        update();
      } else {
        Irssi::print($IRSSI{name} . ": Invalid verification code or it has expired, try again.");
      }
    }
  } else {
    $pcount = $count unless ($count < 0);
    $count = shift @rows;
    my %new;

    if ($count == -2) {
      Irssi::print($IRSSI{name} . ": Unauthorized, access tokens revoked? Clearing authentication status.");
      Irssi::print("Error was: " . $rows[0]);
      clear_auth();
    } elsif ($count == -1) {
      if (Irssi::settings_get_bool('gmail_debug')) {
        Irssi::print($IRSSI{name} . ": update had temporary error: " . $rows[0]);
      }
    } else {
      my $i = 0;

      if ($count > 0) {
        foreach (@rows) {
          $new{@rows[$i]} = time unless $mcache{@rows[$i]};
          $i++;
        }

        if (scalar(keys %new) < 5) {
          foreach (keys %new) {
            awp $_;
          }
        }
      }
    }
    if ($count >= 0) {
      my $i = scalar(%new);
      foreach my $key (sort { $mcache{$b} <=> $mcache{$a} } (keys %mcache)) {
        $new{$key} = $mcache{$key} unless $new{$key};
        last if (++$i >= 100);
      }
      %mcache = %new;
    }
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
        $item->default_handler($get_size_only, "{sb Mail: {nick not authenticated}}", undef, 1);
    } else {
        $item->default_handler($get_size_only, "{sb Mail: $pcount %R(!)%n}", undef, 1);
    }
}

sub escape {
  my ($text) = @_;
  $text =~ s/%/%%/g;
  return $text;
}

sub read_oauth {
  my ($token,$secret);
  if (-e $oauth_store) {
    open ( OAUTH, $oauth_store ) or return 0;
    while (<OAUTH>) {
      chomp;
      if ($_ =~ /^token (\S+)$/) { $token = $1; };
      if ($_ =~ /^secret (\S+)$/) { $secret = $1; };
      last if ($token && $secret);
    }
    close OAUTH;
  }
  if ($token && $secret) {
    $tokens{access_token} = $token;
    $tokens{access_token_secret} = $secret;
    $authed = 1;
    return 1;
  }
  return 0;
}

sub store_oauth {
  my $token = shift || return 0;
  my $secret = shift || return 0;

  open ( OAUTH, ">$oauth_store.new" ) or return 0;
  print OAUTH "token $token\n";
  print OAUTH "secret $secret\n";
  close OAUTH;

  rename "$oauth_store.new", $oauth_store;

  $tokens{access_token} = $token;
  $tokens{access_token_secret} = $secret;
  $tokens{request_token} = undef;
  $tokens{request_token_secret} = undef;
  $authed = 1;

  return 1;
}

sub clear_auth {
  $tokens{access_token} = undef;
  $tokens{access_token_secret} = undef;
  $tokens{request_token} = undef;
  $tokens{request_token_secret} = undef;
  $authed = 0;
  rename $oauth_store, "$oauth_store.old";
  return 1;
}

sub cmd_status {
  my ($data, $server, $item) = @_;
  if ($data =~ m/^[(verify)|((de)?auth)|(help)]/i ) {
    Irssi::command_runsub ('gmail', $data, $server, $item);
  } else {
    Irssi::print($IRSSI{name});
    if ($authed) {
      Irssi::print("  Currently authenticated.");
    } else {
      Irssi::print("  NOT currently authenticated, use /gmail auth to begin.");
    }
  }
}

sub cmd_deauth {
  if ($authed) {
    clear_auth();
    Irssi::print($IRSSI{name} . ": OK, access tokens removed.");
  }
}

sub cmd_verify {
  my $verifier = shift;
  my ($server,$win) = @_;
  unless (length $tokens{request_token} && length $tokens{request_token_secret}) {
    Irssi::print($IRSSI{name} . ": No pending OAuth request. Try /gmail auth first.");
    return 0;
  }

  if ((time - $tokens{request_token_timestamp}) > 600) {
    Irssi::print($IRSSI{name} . ": Pending OAuth request over 10 minutes old and has expired. Try /gmail auth first.");
    return 0;
  }
  if ( oauth_worker("access", {
        tokens => { %tokens },
        verifier => $verifier,
        }) ) {
    return 1;
  }
  Irssi::print($IRSSI{name} . ": cmd_verify failed!");
  return 0;
}

sub cmd_auth {
  my $autoauth = shift;

  if (read_oauth()) {
    Irssi::print($IRSSI{name} . ": Loaded stored access tokens");
  } elsif ($autoauth) {
    Irssi::print($IRSSI{name} . ": No stored access tokens found, use /gmail auth to begin\n"
        . "and remember to add \"mail\" statusbar item to your statusbar.");
    return 0;
  } else {
    do_req_oauth();
  }
}

sub do_req_oauth {
  if (oauth_worker("request", {
    tokens => { %tokens },
  }) ) {
    return 1;
  }
  Irssi::print($IRSSI{name} . ": do_req_oauth failed!");
  return 0;
}

sub update {
  return 1 unless ($authed);
  if (oauth_worker("update", {
      tokens => { %tokens },
  }) ) {
    return 1;
  }
  Irssi::print($IRSSI{name} . ": update() failed immediately!");
  return 0;
}

Irssi::statusbar_item_register("mail", undef, "mail");
Irssi::settings_add_bool('gmail', 'gmail_show_message', 1);
Irssi::settings_add_bool('gmail', 'gmail_show_summary', 1);
Irssi::settings_add_bool('gmail', 'gmail_debug', 0);
Irssi::settings_add_str('gmail', 'gmail_feed_label', undef);

Irssi::command_bind('gmail deauth','cmd_deauth');
Irssi::command_bind('gmail auth','cmd_auth');
Irssi::command_bind('gmail verify','cmd_verify');
Irssi::command_bind('gmail','cmd_status');

Irssi::theme_register(
        [
        'new_gmail_crap',
        '{line_start}%_new%_ %BG%RM%Ya%Bi%Gl%N from %c$0%N with subject %c$1%N %K$2%N'
        ]);

cmd_auth(1);

update();
Irssi::timeout_add(60*1000, "update", undef);
