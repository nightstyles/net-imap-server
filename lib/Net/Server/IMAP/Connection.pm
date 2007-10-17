package Net::Server::IMAP::Connection;

use warnings;
use strict;

use base 'Class::Accessor';

use Net::Server::IMAP::Command;

__PACKAGE__->mk_accessors(qw(server io_handle selected model pending temporary_messages temporary_sequence_map previous_exists untagged_expunge untagged_fetch ignore_flags));

sub new {
    my $class = shift;
    my $self = $class->SUPER::new( { @_, state => "unauth", untagged_expunge => [], untagged_fetch => {} } );
    $self->greeting;
    return $self;
}

sub greeting {
    my $self = shift;
    $self->out( '* OK IMAP4rev1 Server' . "\r\n" );
}

sub handle_command {
    my $self    = shift;
    my $content = $self->io_handle->getline();

    unless ( defined $content ) {
        $self->log("Connection closed by remote host");
        $self->close;
        return;
    }

    $self->log("C: $content");

    if ( $self->pending ) {
        $self->pending->($content);
        return;
    }

    my ( $id, $cmd, $options ) = $self->parse_command($content);
    return unless defined $id;

    my $cmd_class = "Net::Server::IMAP::Command::$cmd";
    $cmd_class->require() || warn $@;
    unless ( $cmd_class->can('run') ) {
        $cmd_class = "Net::Server::IMAP::Command";
    }
    my $handler = $cmd_class->new(
        {   server      => $self->server,
            connection  => $self,
            options_str => $options,
            command_id  => $id,
            command     => $cmd
        }
    );
    return if $handler->has_literal;

    $handler->run() if $handler->validate;
}

sub close {
    my $self = shift;
    $self->server->connections->{ $self->io_handle } = undef;
    $self->server->select->remove( $self->io_handle );
    $self->io_handle->close;
}

sub parse_command {
    my $self = shift;
    my $line = shift;
    $line =~ s/[\r\n]+$//;
    unless ( $line =~ /^([\w\d]+)\s+(\w+)(?:\s+(.+?))?$/ ) {
        if ( $line !~ /^([\w\d]+)\s+/ ) {
            $self->out("* BAD Invalid tag\r\n");
        } else {
            $self->out("* BAD Null command ('$line')\r\n");
        }
        return undef;
    }

    my $id   = $1;
    my $cmd  = $2;
    my $args = $3 || '';
    $cmd = ucfirst( lc($cmd) );
    return ( $id, $cmd, $args );
}

sub is_unauth {
    my $self = shift;
    return not defined $self->auth;
}

sub is_auth {
    my $self = shift;
    return defined $self->auth;
}

sub is_selected {
    my $self = shift;
    return defined $self->selected;
}

sub is_encrypted {
    my $self = shift;
    return $self->io_handle->isa("IO::Socket::SSL");
}

sub auth {
    my $self = shift;
    if (@_) {
        $self->{auth} = shift;
        $self->server->model_class->require || warn $@;
        $self->model(
            $self->server->model_class->new( { auth => $self->{auth} } ) );
    }
    return $self->{auth};
}

sub untagged_response {
    my $self = shift;
    while ( my $message = shift ) {
        next unless $message;
        $self->out( "* " . $message . "\r\n" );
    }
}

sub send_untagged {
    my $self = shift;
    my %args = ( expunged => 1,
                 @_ );
    return unless $self->is_auth and $self->is_selected;

    {
        # When we poll, the things that we find should affect this
        # connection as well; hence, the local to be "connection-less"
        local $Net::Server::IMAP::Server->{connection};
        $self->selected->poll;
    }

    for my $s (keys %{$self->untagged_fetch}) {
        my($m) = $self->get_messages($s);
        $self->untagged_response( $s
                . " FETCH "
                . Net::Server::IMAP::Command->data_out( [ $m->fetch([keys %{$self->untagged_fetch->{$s}}]) ] ) );
    }
    $self->untagged_fetch({});

    if ($args{expunged}) {
        $self->previous_exists( $self->previous_exists - @{$self->untagged_expunge} );
        $self->untagged_response( map {"$_ EXPUNGE"} @{$self->untagged_expunge} );
        $self->untagged_expunge([]);
        $self->temporary_messages(undef);
    }

    my $expected = $self->previous_exists;
    my $now = @{$self->temporary_messages || $self->selected->messages};
    $self->untagged_response( $now . ' EXISTS' ) if $expected != $now;
    $self->previous_exists($now);

}

sub get_messages {
    my $self = shift;
    my $str  = shift;

    my $messages = $self->temporary_messages || $self->selected->messages;

    my @ids;
    for ( split ',', $str ) {
        if (/^(\d+):(\d+)$/) {
            push @ids, $1 .. $2;
        } elsif (/^(\d+):\*$/) {
            push @ids, $1 .. @{ $messages } + 0;
        } elsif (/^(\d+)$/) {
            push @ids, $1;
        }
    }
    return grep {defined} map { $messages->[ $_ - 1 ] } @ids;
}

sub sequence {
    my $self = shift;
    my $message = shift;

    return $message->sequence unless $self->temporary_messages;
    return $self->temporary_sequence_map->{$message};
}


sub log {
    my $self = shift;
    my $msg  = shift;
    chomp($msg);
    warn $msg . "\n";
}

sub out {
    my $self = shift;
    my $msg  = shift;

    if ($self->io_handle) {
        $self->io_handle->print($msg);
        $self->log("S: $msg");
    } else {
        warn "Connection closed unexpectedly\n";
    }

}

1;