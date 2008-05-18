package WebService::Nowa;

use strict;
use warnings;

use 5.8.1;
our $VERSION = '0.01';

use Encode ();
use Scalar::Util qw(blessed);
use List::Util qw(first);
use Web::Scraper;
use Time::HiRes qw(time);
use Carp;
use URI;
use JSON::Syck;
use WWW::Mechanize;
use Crypt::SSLeay;

use constant NOWA_ROOT         => 'http://nowa.jp/';
use constant MY_NOWA_ROOT      => 'http://my.nowa.jp/';
use constant NOWA_HOME         => 'http://my.nowa.jp/home/';
use constant NOWA_INTERNAL_API => 'http://my.nowa.jp/internal_api/';
use constant NOWA_API_HOME     => 'https://api.nowa.jp/';

sub new {
    my $class = shift;
    croak "invalid argument" unless (ref($_[0]) eq 'HASH');
    my $self = shift;
    bless $self, $class;

    my $mech = WWW::Mechanize->new;
    $mech->credentials('api.nowa.jp:443', "nowa API", $self->{nowa_id}, $self->{api_pass});
    $mech->agent_alias('Windows IE 6');
    $self->{mech} = $mech;
    $self->{mech}->stack_depth(1);

    $self;
}

# copyed from Nowa::Nanishiteru
sub _login {
    my $self = shift;

    $self->{mech}->get(NOWA_HOME);
    $self->{_logged_in} = 1 if $self->{mech}->uri eq NOWA_HOME;
    return if $self->{_logged_in};
    my $uri = $self->{mech}->uri;
    $self->{mech}->submit_form(
        form_number => 1,
        fields      => +{
            nowa_id  => $self->{nowa_id},
            password => $self->{password},
        },
    );
    croak("login failed.") if $self->{mech}->uri eq $uri;

    if ($self->{mech}->content =~ m!<script type="text/javascript">\s+\w+\.init\(\s*"([a-f0-9]+)"!s) {
        $self->{rkey} = $1;
    }

    $self->{_logged_in} = 1;
}

# from Web::Scraper
sub _scrape {
    my ($self, $s, $url) = @_;

    my $stuff = $url;
    $stuff = $url->as_string if (blessed($url) && $url->isa('URI'));

    require Encode;
    require HTTP::Response::Encoding;

    my $res = $self->{mech}->get($stuff);
    my @encoding = (
        $res->encoding,
        ($res->header('Content-Type') =~ /charset=([\w\-]+)/g),
        "latin-1",
    );
    my $encoding = first { defined $_ && Encode::find_encoding($_) } @encoding;
    my $html = Encode::decode($encoding, $self->{mech}->content);

    my $base = ($res->content =~ /<base\s+href="([^"]+)"/)[0] || $stuff;

    my $scraped = $s->scrape($html, $base);
    $scraped;
}

sub channels {
    my $self = shift;
    $self->_login unless $self->{_logged_in};

    my $s = scraper {
        process 'ul.home-chlist > li', 'channels[]' => scraper {
            process 'a',
                'name', 'TEXT',
                'link', '@href';
        };
    };
    my $res = $self->_scrape($s, URI->new(NOWA_HOME));
    my $data;
    my $re = NOWA_ROOT . "ch/(.*?)/";
    for my $chan (@{ $res->{channels} }) {
        my $id = '#' . ($chan->{link} =~ m!^$re!)[0];
        my $name = $chan->{name};
        $name =~ s/\(\d+\)$//;
        $data->{$id} = $name;
    }
    return wantarray ? %$data : $data;
}

sub channel_recent {
    my $self = shift;
    $self->_login unless $self->{_logged_in};

    my $s = scraper {
        process 'ul#article-list > li', 'msgs[]' => scraper {
            process_first 'a.blue-cms',
                'user', 'TEXT',
                'userlink', '@href';
            process 'span.body',
                'body', 'TEXT';
            process 'span.body > a',
                'channel', 'TEXT',
                'channellink', '@href';
            process 'span.time > a',
                'permalink', '@href';
        };
    };
    my $res = $self->_scrape($s, URI->new(MY_NOWA_ROOT . 'channel/recent'));
    my @data;
    for my $msg (@{ $res->{msgs} }) {
        next unless $msg->{permalink};

        my $user = ($msg->{userlink} =~ m!^http://([^\.]+)\.nowa\.jp/!)[0];
        my $body = $msg->{body};
        $body =~ s/\s+#\w+$//;

        push(@data, +{
            body => $body,
            user => $user,
            permalink => $msg->{permalink}->as_string,
            channel => $msg->{channel},
        });
    }
    return wantarray ? @data : \@data;
}

sub _api {
    my $self = shift;
    my $method = shift;

    my $uri = URI->new_abs($method, NOWA_API_HOME);
    $self->{mech}->get($uri->as_string);
    my $content = Encode::decode('utf-8', $self->{mech}->content);
    local $JSON::Syck::ImplicitUnicode = 1;
    my $res = JSON::Syck::Load($content);
    croak "fetch recent failed." if ref($res) eq 'HASH' and $res->{result} eq 'fail';
    $res;
}

sub _internal_api {
    my $self = shift;
    my $method = shift;
    my $args = shift;

    my $uri = URI->new_abs($method, NOWA_INTERNAL_API);

    my($sec, $fsec) = time() =~ /^(\d+)(?:\.(\d+))?$/;
    $fsec = substr($fsec, 0, 3);
    $fsec .= '0' while length $fsec < 3;
    my $uniqid = sprintf('%d%d', $sec, $fsec);

    $uri->query_form(
        rkey   => $self->{rkey},
        uniqid => $uniqid,
        %$args
    );
    $self->{mech}->get($uri->as_string);
    my $content = Encode::decode('utf-8', $self->{mech}->content);
    local $JSON::Syck::ImplicitUnicode = 1;
    my $res = JSON::Syck::Load($content);
    croak "fetch internal_api failed." if ref($res) eq 'HASH' and $res->{status} eq 'fail';
    $res;
}

sub recent {
    my $self = shift;

    my $res = $self->_api('/status_message/friends_timeline.json');
    my @data;
    for my $entry (@$res) {
        # skip channel messages
        next if $entry->{text} =~ /^#\w+\s/;

        my $who = $entry->{user}->{nowa_id};
        my $permalink = sprintf("http://%s.nowa.jp/status/%d", $who, (split(/_/, $entry->{id}))[1]);
        my $body = $entry->{text};
        if (my $reply = $entry->{in_reply_to}) {
            $body = sprintf(">%s %s", $reply->{user}->{nowa_id}, $body);
        }

        push(@data, +{
            id        => $entry->{id},
            user      => $entry->{user}->{nowa_id},
            permalink => $permalink,
            body      => $body,
        });
    }

    return wantarray ? @data : \@data;
}

sub update_nanishiteru {
    my($self, $arg) = @_;

    my $uri = URI->new_abs('/status_message/update.json', NOWA_API_HOME);
    $arg = { status => $arg } unless ref($arg) eq 'HASH';
    $self->{mech}->post($uri->as_string, $arg);
    my $res = JSON::Syck::Load($self->{mech}->content);
    croak "fetch recent failed." unless $res->{id} =~ /^\d+_\d+$/;
    $res;
}

sub point {
    my($self) = @_;
    $self->_login unless $self->{_logged_in};

    my $s = scraper {
        process 'dl.point dd', 'point' => sub { 0 + (shift->string_value =~ /^([0-9]+).*/g)[0] }
    };
    my $res = $self->_scrape($s, URI->new(NOWA_HOME));
    return $res->{point};
}

sub add_friend {
    my($self, $target_nowa_id, $body) = @_;

    my $res = $self->_internal_api('./friend/add', { nowa_id => $target_nowa_id, body => $body });
    return $res->{status} eq 'success';
}

sub delete_friend {
    my($self, $target_nowa_id) = @_;

    my $res = $self->_internal_api('./friend/delete', { nowa_id => $target_nowa_id });
    return $res->{status} eq 'success';
}



1;

__END__

=head1 NAME

WebService::Nowa - Perl interface to the Nowa

=head1 SYNOPSIS

  use WebService::Nowa;
  my $config = {
    nowa_id  => 'woremacx',
    password => 'yourpass',
    api_pass => 'apipass',
    # make your api_pass at http://my.nowa.jp/config/account/api_auth
  };
  my $nowa = WebService::Nowa->new($config);
  $nowa->update_nanishiteru('Hello, world, nowa!');

=head1 DESCRIPTION

WebService::Nowa is Perl interface to the Nowa.

Nowa is the community service run by L<http://www.livedoor.com/> in Japan. See L<http://nowa.jp/>

=head1 METHODS

=head2 new

constructor

=head2 channels

get channels you are joining

=head2 channel_recent

get recent messages from all the channels your are joining

=head2 _api

call public json api.

see L<http://wiki.livedoor.jp/nowa_staff/d/nowa%20%A5%CA%A5%CB%A5%B7%A5%C6%A5%EBAPI%BB%C5%CD%CD>

=head2 _internal_api

call internal json api. use with care.

=head2 recent

get recent messages from your timeline

=head2 update_nanishiteru

write nanishiteru message

=head2 point

get nowaen point

=head2 add_friend

add friend

=head2 delete_friend

delete friend

=head1 AUTHOR

woremacx E<lt>woremacx at cpan dot orgE<gt>

mattn

hideden

=head1 LICENSE

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=head1 SEE ALSO

L<http://nowa.jp/>,
L<http://wiki.livedoor.jp/nowa_staff/d/nowa%20%A5%CA%A5%CB%A5%B7%A5%C6%A5%EBAPI%BB%C5%CD%CD>

=cut
