package Net::Server::IMAP::Command::Capability;

use warnings;
use strict;

use base qw/Net::Server::IMAP::Command/;

sub validate {
    my $self = shift;

    my @options = $self->parsed_options;
    return $self->bad_command("Too many options") if @options;

    return 1;
}

sub run {
    my $self = shift;
    $self->tagged_response( $self->server->capability($self->connection) );
    $self->ok_completed;
}

1;