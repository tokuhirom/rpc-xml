package RPC::XML::Server::PSGI;
use strict;
use warnings;
use base qw/RPC::XML::Server/;
use Compress::Zlib ();
use File::Temp ();
use HTTP::Headers;

sub new {
    my $class = shift;
    return $class->SUPER::new(no_http => 1, @_);
}

sub to_app {
    my $self = shift;
    my $me = (ref($self) || $self) . '::to_app';

    sub {
        my $env = shift;
        my $headers_in = HTTP::Headers->new(
            map {
                ( my $field = $_ ) =~ s/^HTTPS?_//;
                ( $field => $env->{$_} );
            }
            grep { /^(?:HTTP|CONTENT|COOKIE)/i } keys %$env
        );

        my @headers = map {
            my $k = $_;
            map { ( $k => $_ ) } $self->response->headers->header($_);
          } $self->response->headers->header_field_names;
        push @headers => (
            'Content-Type'  => 'text/xml',
            'Cache-Control' => 'no-cache',
            'Pragma'        => 'no-cache'
        );

        if ($env->{REQUEST_METHOD} eq 'HEAD') {
            return [200, [@headers, 'Content-Length' => 0], []];
        } elsif ($env->{REQUEST_METHOD} eq 'POST') {
            # Step 1: Do we have the correct content-type?
            if (($env->{CONTENT_TYPE} || '') !~ m{text/xml}i) {
                die "Content-Type should be text/xml";
            }

            my $compress = $self->compress;
            my $do_compress;
            if ($compress and
                ($headers_in->header('Content-Encoding') || q{}) =~ $self->compress_re)
            {
                $do_compress = 1;
            }

            # Step 2: Read the request in and convert it to a request object
            # Note that this currently binds us to the Content-Length header a lot
            # more tightly than I like. Expect to see this change sometime soon.
            my $length = $headers_in->header('Content-Length');
            my $parser = $self->parser->parse(); # Get the ExpatNB object
            my $com_engine;
            if ($do_compress)
            {
                # Spin up the compression engine
                if (! ($com_engine = Compress::Zlib::inflateInit()))
                {
                    die("$me: Unable to init the Compress::Zlib engine");
                }
            }

            my $content;
            while ($length)
            {
                $env->{'psgi.input'}->read($content, ($length < 2048) ? $length : 2048);
                $length -= length $content;
                if ($do_compress)
                {
                    if (! ($content = $com_engine->inflate($content)))
                    {
                        die("$me: Error inflating compressed data");
                    }
                }
                if (! eval { $parser->parse_more($content); 1; })
                {
                    if ($@)
                    {
                        die("$me: XML parse error: $@");
                    }
                }
            }

            if (! eval { $content = $parser->parse_done; 1; })
            {
                if ($@)
                {
                    die("$me: XML parse error at end: $@");
                }
            }

            # Step 3: Process the request and encode the outgoing response
            # Dispatch will always return a RPC::XML::response object
            my $resp;
            {
                # We set some short-lifespan localized keys on $self to let the
                # methods have access to client connection info
                # Set localized keys on $self, based on the connection info
                ## no critic (ProhibitLocalVars)
                local $self->{peeraddr} = $env->{REMOTE_ADDR};
                local $self->{peerhost} = $env->{REMOTE_HOST};
                local $self->{peerport} = undef; # PSGI doesn't support peerport
                $resp = $self->dispatch($content);
            }

            # Step 4: Form up and send the headers and body of the response
            $do_compress = 0; # Clear it
            if ($compress and ($resp->length > $self->compress_thresh) and
                (($headers_in->header('Accept-Encoding') || q{}) =~ $self->compress_re))
            {
                $do_compress = 1;
                push @headers, 'Content-Encoding' => $compress;
            }
            # Determine if we need to spool this to a file due to size
            if ($self->message_file_thresh and
                $self->message_file_thresh < $resp->length)
            {
                my $resp_fh = File::Temp->new(UNLINK => 1);

                # Now that we have it, spool the response to it. This is a
                # little hairy, since we still have to allow for compression.
                # And though the response could theoretically be HUGE, in
                # order to compress we have to write it to a second temp-file
                # first, so that we can compress it into the primary handle.
                if ($do_compress)
                {
                    my $fh2 = File::Temp->new(UNLINK => 1);

                    # Write the request to the second FH
                    $resp->serialize($fh2);
                    seek $fh2, 0, 0;

                    # Spin up the compression engine
                    if (! ($com_engine = Compress::Zlib::deflateInit()))
                    {
                        die("$me: Unable to initialize the " .
                                    'Compress::Zlib engine');
                    }

                    # Spool from the second FH through the compression engine,
                    # into the intended FH.
                    my $buf = q{};
                    my $out;
                    while (read $fh2, $buf, 4096)
                    {
                        if (! (defined($out = $com_engine->deflate(\$buf))))
                        {
                            die("$me: Compression failure in deflate()");
                        }
                        print {$resp_fh} $out;
                    }
                    # Make sure we have all that's left
                    if  (! defined($out = $com_engine->flush))
                    {
                        die("$me: Compression flush failure in deflate");
                    }
                    print {$resp_fh} $out;

                    # Close the secondary FH. Rewinding the primary is done
                    # later.
                    close $fh2; ## no critic (RequireCheckedClose)
                }
                else
                {
                    $resp->serialize($resp_fh);
                }
                seek $resp_fh, 0, 0;

                return [200, [@headers, 'Content-Length' => (-s $resp_fh)], $resp_fh];
            }
            else
            {
                # Treat the content strictly in-memory
                my $content = $resp->as_string;
                if ($do_compress) {
                    $content = Compress::Zlib::compress($content);
                }
                return [200, [@headers, 'Content-Length' => length($content)], [$content]];
            }
        } else {
            return [403, ['Content-Length' => 0], []];
        }
    }
}

1;
