package CIF::Smrt::Fetcher;

use strict;
use warnings;

use Mouse;
use CIF qw/$Logger hash_create_static/;
use File::Spec;

use LWP::UserAgent;
use Mouse;
use Carp;
use Carp::Assert;
use Net::SSLeay;
use File::Path qw(make_path);
use File::Spec;
use CIF qw/$Logger/;
use File::Slurp; ## we can always re-factorize this
Net::SSLeay::SSLeay_add_ssl_algorithms(); ## TODO -- this needs cleaning up
use Try::Tiny;

use constant {
    CAPACITY   => 5,
    TLS_VERIFY => 1,
    TIMEOUT    => 300,
    AGENT => 'cif-smrt/'.CIF::VERSION().' ('.CIF::ORG().')',
};

has 'agent'     => (
    is      => 'ro',
    default => AGENT,
);

has [qw(rule test_mode tmp username password proxy https_proxy)] => (
    is      => 'ro'
);

has 'handle' => (
    is          => 'ro',
    lazy_build  => 1,
);

sub _build_handle {
    my $self = shift;
    my $args = shift;
    
    my $agent = LWP::UserAgent->new(
        agent       => AGENT,
        timeout     => $args->{'timeout'} || TIMEOUT,
        conn_cache  => { 
            total_capacity  => $args->{'capacity'} || CAPACITY
        },
    );
    
    # set both just in case we have legacy stuff laying around
    if(defined($args->{'tls_verify'}) && !$args->{'tls_verify'}){
        $agent->ssl_opts(SSL_verify_mode => 0);
        $agent->ssl_opts(verify_hostname => 0);
    } else {
        $agent->ssl_opts(SSL_verify_mode => 1);
    }

    $agent->env_proxy();
    if($self->proxy){
        $agent->proxy(['http','https'],$self->{'proxy'});
    }
    if($self->https_proxy){
        $agent->proxy(['https'],$self->{'https_proxy'});
    }

    return $agent;
}

sub process {
    my $self = shift;
    my $args = shift;
    
    my ($ret,$err);
    
    unless($self->test_mode() && -e $self->tmp){ ## testmode cleans out the cache
        if(-e $self->rule->defaults->{'remote'}){
            return read_file($self->rule->defaults->{'remote'});
        } else {
            $Logger->debug('pulling: '.$self->rule->defaults->{'remote'});
            try {
                if($self->rule->defaults->{'username'} && $self->rule->defaults->{'password'}){
                    if($self->rule->defaults->{'realm'}){
                        $self->handle->credentials($self->rule->defaults->{'netloc'}, $self->rule->defaults->{'realm'}, $self->rule->defaults->{'username'}, $self->rule->defaults->{'password'});
                        $ret = $self->handle->get($self->rule->defaults->{'remote'});
                    } else {
                        my $req = HTTP::Request->new(GET => $self->rule->defaults->{'remote'});
                        $req->authorization_basic($self->rule->defaults->{'username'},$self->rule->defaults->{'password'});
                        $ret = $self->handle->request($req);
                    }
                } else {
                    if($self->rule->token){
                        $self->handle->default_header('Authorization' => 'Token token='.$self->rule->token);
                    }
                    $ret = $self->handle->mirror($self->rule->defaults->{'remote'}, $self->tmp);
                }
            } catch {
                $err = shift;
                $Logger->fatal($err);
                $Logger->fatal('possible timeout grabbing the feed');
            };
            
            return 0 unless($ret);
            
            if($ret->status_line()){
                $Logger->debug('status: '.$ret->status_line());
            }
            unless($ret->is_success() || $ret->status_line() =~ /^304 /){
                if($ret->status_line()){
                    $Logger->error($ret->status_line());
                }
                return;
            } else {
                $ret = $ret->decoded_content();
            }
        }
    }
    if(-e $self->tmp){
        return read_file($self->tmp, binmode => ':raw');
    } else {
        return $ret;
    }
}

__PACKAGE__->meta->make_immutable();

1;
