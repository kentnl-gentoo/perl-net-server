# -*- perl -*-
#
#  Net::Server::Fork - Net::Server personality
#  
#  $Id: Fork.pm,v 1.15 2001/03/20 06:07:33 rhandom Exp $
#  
#  Copyright (C) 2001, Paul T Seamons
#                      paul@seamons.com
#                      http://seamons.com/
#  
#  This package may be distributed under the terms of either the
#  GNU General Public License 
#    or the
#  Perl Artistic License
#
#  All rights reserved.
#  
################################################################

package Net::Server::Fork;

use strict;
use vars qw($VERSION @ISA);
use Net::Server;
use POSIX qw(WNOHANG);

$VERSION = $Net::Server::VERSION; # done until separated

### fall back to parent methods
@ISA = qw(Net::Server);


### make sure some defaults are set
sub post_configure {
  my $self = shift;
  my $prop = $self->{server};

  ### let the parent do the rest
  $self->SUPER::post_configure;

  ### how often to see if children are alive
  $prop->{check_for_dead} = 30
    unless defined $prop->{check_for_dead};

  ### I need to know who is the parent
  $prop->{ppid} = $$;

}


### loop, fork, and process connections
sub loop {
  my $self = shift;
  my $prop = $self->{server};

  ### get ready for children
  $SIG{CHLD} = \&sig_chld;
  $prop->{children} = {};

  my $last_checked_for_dead = time;

  ### this is the main loop
  while( $self->accept ){

    my $pid = fork;
      
    ### trouble
    if( not defined $pid ){
      $self->log(1,"Bad fork [$!]");
      sleep(5);
        
    ### parent
    }elsif( $pid ){

      close($prop->{client});
      $prop->{children}->{$pid} = time;
        
    ### child
    }else{

      $self->run_client_connection;
      exit;

    }

    my $time = time;

    ### periodically see which children are alive
    if( $time - $last_checked_for_dead > $prop->{check_for_dead} ){
      $last_checked_for_dead = $time;
      foreach (keys %{ $prop->{children} }){
        ### see if the child can be killed
        kill(0,$_) or delete $prop->{children}->{$_};
      }
    }

  }
}

### routine to avoid zombie children
sub sig_chld {
  1 while (waitpid(-1, WNOHANG) > 0);
  $SIG{CHLD} = \&sig_chld;
}

### override a little to restore sigs
sub run_client_connection {
  my $self = shift;

  ### close the main sock, we still have
  ### the client handle, this will allow us
  ### to HUP the parent at any time
  $_ = undef foreach @{ $self->{sock} };

  ### restore sigs (turn off warnings during)
  my $W = $^W; $^W = 0;
  $SIG{INT} = $SIG{TERM} = $SIG{QUIT} = undef;
  $^W = $W;

  $self->SUPER::run_client_connection;

}

### routine to shut down the server (and all forked children)
sub server_close {
  my $self = shift;
  my $prop = $self->{server};

  my $W = $^W; $^W = 0;
  $SIG{INT} = undef;
  $^W = $W;

  ### if a parent, fork off cleanup sub and close
  if( ! defined $prop->{ppid} || $prop->{ppid} == $$ ){

    $self->log(2,$self->log_time . " Server closing!!!");
    $self->close_children;
    exit;

  ### if a child, signal the parent and close
  ### normally the child shouldn't, but if they do...
  }else{
    kill(2,$prop->{ppid});
    exit;
  }

}

### Fork another process (that won't deal with sig chld's) to
### sig int the children and then exit itself
sub close_children {
  my $self = shift;
  my $prop = $self->{server};

  if( defined $prop->{children} && %{ $prop->{children} } ){

    my $pid = fork;
    if( not defined $pid ){
      $self->log(1,"Can't fork to clean children [$!]");
    }
    return if $pid;

    foreach (keys %{ $prop->{children} }){
      kill(2,$_);
    }

  }
  
  ### remove extra files
  if( defined $prop->{pid_file}
      && -e $prop->{pid_file}
      && defined $prop->{pid_file_unlink} ){
    unlink $prop->{pid_file};
  }

  exit;
}


1;

__END__

=head1 NAME

Net::Server::Fork - Net::Server personality

=head1 SYNOPSIS

  use Net::Server::Fork;
  @ISA = qw(Net::Server::Fork);

  sub process_request {
     #...code...
  }

  Net::Server::Fork->run();

=head1 DESCRIPTION

Please read the pod on Net::Server first.  This module
is a personality, or extension, or sub class, of the
Net::Server module.

This personality binds to one or more ports and then waits
for a client connection.  When a connection is received,
the server forks a child.  The child handles the request
and then closes.

=head1 ARGUMENTS

There are no additional arguments beyond the Net::Server
base class.

=head1 CONFIGURATION FILE

See L<Net::Server>.

=head1 PROCESS FLOW

Process flow follows Net::Server until the post_accept phase.
At this point a child is forked.  The parent is immediately
able to wait for another request.  The child handles the 
request and then exits.

=head1 HOOKS

There are no additional hooks in Net::Server::Fork.

=head1 TO DO

See L<Net::Server>

=head1 FILES

  The following files are installed as part of this
  distribution.

  Net/Server.pm
  Net/Server/Fork.pm
  Net/Server/INET.pm
  Net/Server/MultiType.pm
  Net/Server/PreFork.pm
  Net/Server/Single.pm

=head1 AUTHOR

Paul T. Seamons paul@seamons.com

=head1 SEE ALSO

Please see also
L<Net::Server::Fork>,
L<Net::Server::INET>,
L<Net::Server::PreFork>,
L<Net::Server::MultiType>,
L<Net::Server::Single>

=cut

