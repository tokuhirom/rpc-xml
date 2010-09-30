use strict;
use warnings;
use Test::More;
use RPC::XML;
use RPC::XML::Server::PSGI;
use Compress::Zlib ();

plan "This test requires Plack::Test" unless eval "require Plack::Test; 1";
plan tests => 16;

my $srv = RPC::XML::Server::PSGI->new();
$srv->add_proc(
    {
        name      => 'echo',
        code      => sub { return $_[0] },
        signature => ['string int'],
    }
);
my $app = $srv->to_app;

Plack::Test::test_psgi(
    app => $app,
    client => sub {
        my $cb = shift;

        { # GET should be 403
            my $req = HTTP::Request->new(GET => "http://localhost/");
            my $res = $cb->($req);
            is $res->code, 403;
            diag $res->content if $res->code ne 403;
        }

        { # HEAD
            my $req = HTTP::Request->new(HEAD => "http://localhost/");
            my $res = $cb->($req);
            is $res->code, 200;
            is $res->content, '';
            is $res->content_length, 0;
        }

        { # POST without valid content-type
            my $req = HTTP::Request->new(POST => "http://localhost/", [], 'foo=bar');
            my $res = $cb->($req);
            is $res->code, 500;
        }

        { # POST
            my $rpc_req     = RPC::XML::request->new( 'echo', 1192 );
            my $rpc_content = $rpc_req->as_string;
            my $req = HTTP::Request->new(POST => "http://localhost/", ['Content-Type' => 'text/xml', 'Content-Length' => length($rpc_content)], $rpc_content);
            my $res = $cb->($req);
            is $res->code, 200;
            is $res->content, '<?xml version="1.0" encoding="us-ascii"?><methodResponse><params><param><value><string>1192</string></value></param></params></methodResponse>';
            isnt $res->content_length, 0;
        }

        { # POST(default methods)
            my $rpc_req     = RPC::XML::request->new( 'system.identity' );
            my $rpc_content = $rpc_req->as_string;
            my $req = HTTP::Request->new(POST => "http://localhost/", ['Content-Type' => 'text/xml', 'Content-Length' => length($rpc_content)], $rpc_content);
            my $res = $cb->($req);
            is $res->code, 200;
            like $res->content, qr{\Q<?xml version="1.0" encoding="us-ascii"?><methodResponse><params><param><value><string>RPC::XML::Server::PSGI/\E[0-9.]+\Q</string></value></param></params></methodResponse>};
            isnt $res->content_length, 0;
        }

        { # POST with file
            $srv->message_file_thresh(1);

            my $rpc_req     = RPC::XML::request->new( 'echo', 1192 );
            my $rpc_content = $rpc_req->as_string;
            my $req = HTTP::Request->new(POST => "http://localhost/", ['Content-Type' => 'text/xml', 'Content-Length' => length($rpc_content)], $rpc_content);
            my $res = $cb->($req);
            is $res->code, 200;
            is $res->content, '<?xml version="1.0" encoding="us-ascii"?><methodResponse><params><param><value><string>1192</string></value></param></params></methodResponse>';
            isnt $res->content_length, 0;
        }

        { # POST with compression
            $srv->compress_thresh(1);

            my $rpc_req     = RPC::XML::request->new( 'echo', 1192 );
            my $rpc_content = $rpc_req->as_string;
            my $req = HTTP::Request->new(POST => "http://localhost/", ['Accept-Encoding' => 'deflate', 'Content-Type' => 'text/xml', 'Content-Length' => length($rpc_content)], $rpc_content);
            my $res = $cb->($req);
            is $res->code, 200;
            is Compress::Zlib::uncompress($res->content), '<?xml version="1.0" encoding="us-ascii"?><methodResponse><params><param><value><string>1192</string></value></param></params></methodResponse>';
        }
    }
);

