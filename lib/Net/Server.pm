# -*- perl -*-
#
#  Net::Server - adpO - Extensible Perl internet server
#  
#  $Id: Server.pm,v 1.90 2001/03/20 06:42:08 rhandom Exp $
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
#  Please read the perldoc Net::Server
#
################################################################

package Net::Server;

use strict;
use Socket qw( inet_aton inet_ntoa unpack_sockaddr_in AF_INET );
use IO::Socket ();

$Net::Server::VERSION = '0.55';

### program flow
sub run {

  ### pass package or object
  my $self = ref($_[0]) ? shift() : (bless {}, shift());

  ### need a place to store properties
  $self->{server} = {} unless defined($self->{server}) && ref($self->{server});

  ### save for a HUP
  $self->{server}->{commandline} = [ $0, @ARGV ]
    unless defined $self->{server}->{commandline};

  $self->configure_hook;      # user customizable hook

  $self->configure(@_);       # allow for reading of commandline,
                              # program, and configuration file parameters

  $self->post_configure;      # verification of passed parameters

  $self->post_configure_hook; # user customizable hook

  $self->pre_bind;            # finalize ports to be bound

  $self->bind;                # connect to port(s)
                              # setup selection handle for multi port

  $self->post_bind_hook;      # user customizable hook

  $self->post_bind;           # allow for chrooting,
                              # becoming a different user and group

  $self->pre_loop_hook;       # user customizable hook

  $self->loop;                # repeat accept/process cycle

  ### routines inside a standard $self->loop
  # $self->accept             # wait for client connection
  # $self->run_client_connection # process client
  # $self->done               # indicate if connection is done

  $self->pre_server_close_hook;  # user customizable hook

  $self->server_close;        # close the server and release the port

  exit;
}

### standard connection flow
sub run_client_connection {
  my $self = shift;

  $self->post_accept;         # prepare client for processing

  $self->get_client_info;     # determines information about peer and local

  $self->post_accept_hook;    # user customizable hook

  if( $self->allow_deny             # do allow/deny check on client info
      && $self->allow_deny_hook ){  # user customizable hook
    
    $self->process_request;   # This is where the core functionality
                              # of a Net::Server should be.  This is the
                              # only method necessary to override.
  }else{

    $self->request_denied_hook;     # user customizable hook

  }

  $self->post_process_request_hook; # user customizable hook

  $self->post_process_request;      # clean up client connection, etc

}


###----------------------------------------------------------###


### any pre-initialization stuff
sub configure_hook {}


### set up the object a little bit better
sub configure {
  my $self = shift;
  my $prop = $self->{server};

  ### do command line
  $self->process_args( \@ARGV ) if defined @ARGV;

  ### do startup file args
  $self->process_args( \@_ ) if defined @_;

  ### do a config file
  if( defined $prop->{conf_file} ){
    $self->process_conf( $prop->{conf_file} );
  }

}


### make sure it has been configured properly
sub post_configure {
  my $self = shift;
  my $prop = $self->{server};

  ### set the log level
  if( !defined $prop->{log_level} || $prop->{log_level} !~ /^\d+$/ ){
    $prop->{log_level} = 2;
  }
  $prop->{log_level} = 4 if $prop->{log_level} > 4;

    
  ### log to STDERR
  if( ! defined($prop->{log_file}) ){
    $prop->{log_file} = '';

  ### log to syslog
  }elsif( $prop->{log_file} eq 'Sys::Syslog' ){
    
    my $logsock = defined($prop->{syslog_logsock})
      ? $prop->{syslog_logsock} : 'unix';
    $prop->{syslog_logsock} = ($logsock =~ /^(unix|inet)$/)
      ? $1 : 'unix';
    
    my $ident = defined($prop->{syslog_ident})
      ? $prop->{syslog_ident} : 'net_server';
    $prop->{syslog_ident} = ($ident =~ /^(\w+)$/)
      ? $1 : 'net_server';
    
    my $opt = defined($prop->{syslog_logopt})
      ? $prop->{syslog_logopt} : 'pid';
    $prop->{syslog_logopt} = ($opt =~ /^((cons|ndelay|nowait|pid)($|\|))*/)
      ? $1 : 'pid';

    my $fac = defined($prop->{syslog_facility})
      ? $prop->{syslog_facility} : 'daemon';
    $prop->{syslog_facility} = ($fac =~ /^((\w+)($|\|))*/)
      ? $1 : 'daemon';

    require "Sys/Syslog.pm";
    Sys::Syslog::setlogsock($prop->{syslog_logsock}) || die "Syslog err [$!]";
    Sys::Syslog::openlog(   $prop->{syslog_ident},
                            $prop->{syslog_logopt},
                            $prop->{syslog_facility},
                            ) || die "Couldn't open syslog [$!]";

  ### open a logging file
  }elsif( $prop->{log_file} ){

    die "Unsecure filename \"$prop->{log_file}\""
      unless $prop->{log_file} =~ m|^([\w\.\-/]+)$|;
    $prop->{log_file} = $1;
    open(_SERVER_LOG, ">>$prop->{log_file}")
      or die "Couldn't open log file \"$prop->{log_file}\" [$!].";
    _SERVER_LOG->autoflush(1);

  }
  
  ### background the process
  if( defined($prop->{background}) || defined($prop->{setsid}) ){
    my $pid = fork;
    if( not defined $pid ){ $self->fatal("Couldn't fork [$!]"); }
    exit if $pid;
    $self->log(2,"Process Backgrounded");
  }

  ### completely remove myself from parent process
  if( defined($prop->{setsid}) ){
    require "POSIX.pm";
    POSIX::setsid();
  }

  ### make sure that allow and deny look like array refs
  $prop->{allow} = [] unless defined($prop->{allow}) && ref($prop->{allow});
  $prop->{deny}  = [] unless defined($prop->{deny})  && ref($prop->{deny} );

}


### user customizable hook
sub post_configure_hook {}


### make sure we have good port parameters
sub pre_bind {
  my $self = shift;
  my $prop = $self->{server};

  $self->log(2,$self->log_time ." ". ref($self) ." starting!!! pid($$)");

  ### set a default port, host, and proto
  if( ! defined( $prop->{port} )
      || ! ref( $prop->{port} )
      || ! @{ $prop->{port} } ){
    $self->log(2,"Port Not Defined.  Defaulting to '20203'\n");
    $prop->{port}  = [ 20203 ];
  }

  $prop->{host} = '*' unless defined($prop->{host});
  $prop->{host} = ($prop->{host}=~/^([\w\.\-\*\/]+)$/)
    ? $1 : $self->fatal("Unsecure host \"$prop->{host}\"");

  $prop->{proto} = 'tcp' unless defined($prop->{proto});
  $prop->{proto} = ($prop->{proto}=~/^(\w+)$/)
    ? $1 : $self->fatal("Unsecure proto \"$prop->{host}\"");

  ### loop through the passed ports
  ### set up parallel arrays of hosts, ports, and protos
  foreach (@{ $prop->{port} }){
    if( m|^([\w\.\-\*\/]+):(\w+)/(\w+)$| ){
      $_ = "$1:$2:$3";
    }elsif( /^([\w\.\-\*\/]+):(\w+)$/ ){
      my $proto = $prop->{proto};
      $_ = "$1:$2:$proto";
    }elsif( /^(\w+)$/ ){
      my $host  = $prop->{host};
      my $proto = $prop->{proto};
      $_ = "$host:$1:$proto";
    }else{
      $self->fatal("Undeterminate port \"$_\"");
    }
  }
  if( @{ $prop->{port} } < 1 ){
    $self->fatal("No valid ports found");
  }

  $prop->{listen} = 10
    unless defined($prop->{listen}) && $prop->{listen} =~ /^\d{1,3}$/;

}


### bind to the port (This should serve all but INET)
sub bind {
  my $self = shift;
  my $prop = $self->{server};

  ### connect to any ports
  foreach (my($i)=0 ; $i<=$#{ $prop->{port} } ; $i++){
    my ($host,$port,$proto) = split(/:/, $prop->{port}->[$i]);
    $self->log(2,"Binding to $proto port $port on host $host\n");

    my %args = (LocalPort => $port,
                Proto     => $proto,
                Listen    => $prop->{listen},
                Reuse     => 1,);
    $args{LocalAddr} = $host if $host !~ /\*/;

    $prop->{sock}->[$i] = IO::Socket::INET->new( %args )
          or $self->fatal("Can't connect to $proto port $port on $host [$!]");

    $self->fatal("Back sock [$i]!")
      unless $prop->{sock}->[$i];
  }

  ### if more than one port, we'll need to select on it
  if( @{ $prop->{sock} } > 1 ){
    $prop->{multi_port} = 1;
    require "IO/Select.pm";
    $prop->{select} = IO::Select->new();
    foreach ( @{ $prop->{sock} } ){
      $prop->{select}->add( $_ );
    }
  }else{
    $prop->{multi_port} = undef;
    $prop->{select}     = undef;
  }

}


### user customizable hook
sub post_bind_hook {}


### secure the process and background it
sub post_bind {
  my $self = shift;
  my $prop = $self->{server};

  ### perform the chroot operation
  if( defined $prop->{chroot} ){
    if( ! -d $prop->{chroot} ){
      $self->fatal("Specified chroot \"$prop->{chroot}\" doesn't exist.\n");
    }else{
      $self->log(2,"Chrooting to $prop->{chroot}\n");
      chroot( $prop->{chroot} )
        or $self->fatal("Couldn't chroot to \"$prop->{chroot}\"");
    }
  }
  
  ### become another group
  if( !defined $prop->{group} ){
    $self->log(1,"Group Not Defined.  Defaulting to 'nobody'\n");
    $prop->{group}  = 'nobody';
  }
  $self->log(2,"Setting group to $prop->{group}\n");
  $prop->{group} = getgrnam( $prop->{group} )
    if $prop->{group} =~ /\D/;
  $( = $) = $prop->{group};

  ### become another user
  if( !defined $prop->{user} ){
    $self->log(1,"User Not Defined.  Defaulting to 'nobody'\n");
    $prop->{user}  = 'nobody';
  }
  $self->log(2,"Setting user to $prop->{user}\n");
  $prop->{user}  = getpwnam( $prop->{user} )
    if $prop->{user}  =~ /\D/;
  $< = $> = $prop->{user};

  ### allow for a pid file (must be done after backgrounding)
  if( defined $prop->{pid_file} ){
    $prop->{pid_file_unlink} = undef;
    unless( $prop->{pid_file} =~ m|^([\w\.\-/]+)$| ){
      $self->fatal("Unsecure filename \"$prop->{pid_file}\"");
    }
    $prop->{pid_file} = $1;
    $self->log(1,"pid_file \"$prop->{pid_file}\" already exists.  Overwriting.")
      if -e $prop->{pid_file};
    if( open(PID, ">$prop->{pid_file}") ){
      print PID $$;
      close PID;
      $prop->{pid_file_unlink} = 1;
    }else{
      $self->fatal("Couldn't open pid file \"$prop->{pid_file}\" [$!].");
    }
  }

  ### record number of request
  $prop->{requests} = 0;

  ### set some sigs
  $SIG{INT} = $SIG{TERM} = $SIG{QUIT} = sub { $self->server_close; };

  ### catch sighup
  $SIG{HUP} = sub { $self->sig_hup; }

}


### user customizable hook
sub pre_loop_hook {}


### receive requests
sub loop {
  my $self = shift;

  while( $self->accept ){

    $self->run_client_connection;

    last if $self->done;

  }
}


### wait for the connection
sub accept {
  my $self = shift;
  my $prop = $self->{server};
  my $sock = undef;
  my $retries = 30;

  ### try awhile to get a defined client handle
  ### normally a good handle should occur every time
  while( $retries-- ){

    ### with more than one port, use select to get the next one
    if( defined $prop->{multi_port} ){

      ### anything server type specific
      $sock = $self->accept_multi_port;
      
    ### single port is bound - just accept
    }else{

      $sock = $prop->{sock}->[0];

    }

    ### make sure we got a good sock
    if( not defined $sock ){
      $self->fatal("Recieved a bad sock!");
    }

    $prop->{client} = $sock->accept();
    
    ### success
    return 1 if defined $prop->{client};

    ### try again in a second
    sleep(1);

  }

  return undef;
}


### server specific hook for multi port applications
### this actually applies to all but INET
sub accept_multi_port {
  my $self = shift;
  my $prop = $self->{server};

  if( not exists $prop->{select} ){
    $self->fatal("No select property during multi_port execution.");
  }

  ### this will block until a client arrives
  my @waiting = $prop->{select}->can_read();

  ### choose a socket
  return $waiting[ rand(@waiting) ];

}


### this occurs after the request has been processed
### this is server type specific (actually applies to all by INET)
sub post_accept {
  my $self = shift;
  my $prop = $self->{server};

  ### keep track of the requests
  $prop->{requests} ++;

  ### duplicate some handles and flush them
  ### maybe we should save these somewhere - maybe not
  *STDIN  = \*{ $prop->{client} };
  *STDOUT = \*{ $prop->{client} };
  STDIN->autoflush(1);
  STDOUT->autoflush(1);
  select(STDOUT);

}


### read information about the client connection
sub get_client_info {
  my $self = shift;
  my $prop = $self->{server};

  ### read information about this connection
  my $sockname = getsockname( STDIN );
  if( $sockname ){
    ($prop->{sockport}, $prop->{sockaddr})
      = unpack_sockaddr_in( $sockname );
    $prop->{sockaddr} = inet_ntoa( $prop->{sockaddr} );

  }else{
    ### does this only happen from command line?
    $prop->{sockaddr} = '0.0.0.0';
    $prop->{sockhost} = 'inet.test';
    $prop->{sockport} = 0;
  }
  
  ### try to get some info about the remote host
  my $peername = getpeername( STDIN );
  if( $peername ){
    ($prop->{peerport}, $prop->{peeraddr})
      = unpack_sockaddr_in( $peername );
    $prop->{peeraddr} = inet_ntoa( $prop->{peeraddr} );

    if( defined $prop->{reverse_lookups} ){
      $prop->{peerhost} = gethostbyaddr( inet_aton($prop->{peeraddr}), AF_INET );
    }
    $prop->{peerhost} = '' unless defined $prop->{peerhost};

  }else{
    ### does this only happen from command line?
    $prop->{peeraddr} = '0.0.0.0';
    $prop->{peerhost} = 'inet.test';
    $prop->{peerport} = 0;
  }

  $self->log(3,$self->log_time
             ." CONNECT peer: \"$prop->{peeraddr}:$prop->{peerport}\""
             ." local: \"$prop->{sockaddr}:$prop->{sockport}\"\n");

}

### user customizable hook
sub post_accept_hook {}


### perform basic allow/deny service
sub allow_deny {
  my $self = shift;
  my $prop = $self->{server};

  ### if no allow or deny parameters are set, allow all
  return 1 unless @{ $prop->{allow} } || @{ $prop->{deny} };

  ### if the addr or host matches a deny, reject it immediately
  foreach ( @{ $prop->{deny} } ){
    return 0 if $prop->{peerhost} =~ /^$_$/ && defined($prop->{reverse_lookups});
    return 0 if $prop->{peeraddr} =~ /^$_$/;
  }

  ### if the addr or host isn't blocked yet, allow it if it is allowed
  foreach ( @{ $prop->{allow} } ){
    return 1 if $prop->{peerhost} =~ /^$_$/ && defined($prop->{reverse_lookups});
    return 1 if $prop->{peeraddr} =~ /^$_$/;
  }

  return 0;
}


### user customizable hook
### if this hook returns 1 the request is processed
### if this hook returns 0 the request is denied
sub allow_deny_hook { 1 }


### user customizable hook
sub request_denied_hook {}


### this is the main method to override
### this is where most of the work will occur
### A sample server is shown below.
sub process_request {
  my $self   = shift;

  print "Welcome to \"".ref($self)."\" ($$)\n";

  ### eval block needed to prevent DoS by using timeout
  eval {

    local $SIG{ALRM} = sub { die "Timed Out!\n" };
    my $timeout = 30; # give the user 30 seconds to type a line
    my $previous_alarm = alarm($timeout);

    while( <STDIN> ){
      
      s/\r?\n$//;
      
      print ref($self),":$$: You said \"$_\"\r\n";
      $self->log(4,$_); # very verbose log
      
      if( /get (\w+)/ ){
        print "$1: $self->{server}->{$1}\r\n";
      }

      if( /dump/ ){
        require "Data/Dumper.pm";
        print Data::Dumper::Dumper( $self );
      }
      
      if( /quit/ ){ last }
      
      if( /exit/ ){ $self->server_close }
      
      alarm($timeout);
    }
    alarm($previous_alarm);

  };

  if( $@=~/timed out/i ){
    print STDOUT "Timed Out.\r\n";
    return;
  }

}


### user customizable hook
sub post_process_request_hook {}


### this is server type specific functions after the process
sub post_process_request {
  my $self = shift;
  my $prop = $self->{server};

  ### close the socket handle
  close($prop->{client});

}


### determine if I am done with a request
### in the base type, we are never done until a SIG occurs
sub done { 0 }


### user customizable hook
sub pre_server_close_hook {}


### this happens when the server reaches the end
sub server_close{
  my $self = shift;
  my $prop = $self->{server};
  if( defined $prop->{pid_file}
      && -e $prop->{pid_file} 
      && defined $prop->{pid_file_unlink} ){
    unlink $prop->{pid_file};
  }
  exit;
}


### handle sighup - for now, just close the server
### eventually this should re-exec
sub sig_hup {
  my $self = shift;
  $self->fatal("Sig HUP not implemented");
}

###----------------------------------------------------------###

### what to do when all else fails
sub fatal {
  my $self = shift;
  my $error = shift;
  my ($package,$file,$line) = caller;
  $self->fatal_hook($error, $package, $file, $line);

  $self->log(0, $self->log_time ." ". $error
             ."\n  at line $line in file $file");

  $self->server_close;
}


### user customizable hook
sub fatal_hook {}

###----------------------------------------------------------###

### how internal levels map to syslog levels
$Net::Server::syslog_map = {0 => 'err',
                            1 => 'warning',
                            2 => 'notice',
                            3 => 'info',
                            4 => 'debug'};

### record output
sub log {
  my $self  = shift;
  my $prop = $self->{server};
  my $level = shift;

  return unless $prop->{log_level};
  return unless $level <= $prop->{log_level};

  ### log only to syslog if setup to do syslog
  if( $prop->{log_file} eq 'Sys::Syslog' ){
    $level = $level!~/^\d+$/ ? $level : $Net::Server::syslog_map->{$level} ;
    Sys::Syslog::syslog($level,@_);
    return;
  }

  $self->write_to_log_hook($level,@_);
}


### standard log routine, this could very easily be
### overridden with a syslog call
sub write_to_log_hook {
  my $self  = shift;
  my $prop = $self->{server};
  my $level = shift;
  local $_  = shift || '';
  chomp;
  s/([^\n\ -\~])/sprintf("%%%02X",ord($1))/eg;
  
  if( $prop->{log_file} ){
    print _SERVER_LOG $_, "\n";
  }else{
    my $old = select(STDERR);
    print $_, "\n";
    select($old);
  }

}


### default time format
sub log_time {
  my ($sec,$min,$hour,$day,$mon,$year) = localtime;
  return sprintf("%04d/%02d/%02d-%02d:%02d:%02d",
                 $year+1900, $mon+1, $day, $hour, $min, $sec);
}

###----------------------------------------------------------###

### set up default structure
sub options {
  my $self = shift;
  my $prop = $self->{server};
  my $ref  = shift;

  foreach ( qw(port allow deny) ){
    $prop->{$_} = [] unless exists $prop->{$_};
    $ref->{$_} = $prop->{$_};
  }

  foreach ( qw(conf_file
               user group chroot log_level
               log_file pid_file background setsid
               host proto listen reverse_lookups
               syslog_logsock syslog_ident
               syslog_logopt syslog_facility) ){
    $ref->{$_} = \$prop->{$_};
  }

}


### routine for parsing commandline, module, and conf file
### possibly should use Getopt::Long but this
### method has the benefit of leaving unused arguments in @ARGV
sub process_args {
  my $self = shift;
  my $ref  = shift;
  my $template = {};
  $self->options( $template );

  foreach (my $i=0 ; $i < @$ref ; $i++ ){

    if( $ref->[$i] =~ /^(?:--)?(\w+)([=\ ](\S+))?$/
        && exists $template->{$1} ){
      my ($key,$val) = ($1,$3);
      splice( @$ref, $i, 1 );
      $val = splice( @$ref, $i, 1 ) if not defined $val;
      $i--;
      $val =~ s/%([A-F0-9])/chr(hex($1))/eig;

      if( ref $template->{$key} eq 'ARRAY' ){
        push( @{ $template->{$key} }, $val );
      }else{
        $ { $template->{$key} } = $val;
      }
    }

  }
}


### routine for loading conf file parameters
sub process_conf {
  my $self = shift;
  my $file = shift;
  my @args = ();

  $file = ($file =~ m|^([\w\.\-/]+)$|)
    ? $1 : $self->fatal("Unsecure filename \"$file\"");

  if( not open(_CONF,"<$file") ){
    $self->fatal("Couldn't open conf \"$file\" [$!]");
  }

  while(<_CONF>){
    push( @args, "$1=$2") if m/^\s*((?:--)?\w+)[=:]?\s*(\S+)/;
  }

  close(_CONF);

  $self->process_args( \@args );
}


###----------------------------------------------------------###
sub get_property {
  my $self = shift;
  my $key  = shift;
  $self->{server} = {} unless defined $self->{server};
  return $self->{server}->{$key} if exists $self->{server}->{$key};
  return undef;
}

sub set_property {
  my $self = shift;
  my $key  = shift;
  $self->{server} = {} unless defined $self->{server};
  $self->{server}->{$key}  = shift;
}

1;

__END__

=head1 NAME

Net::Server - Extensible, general Perl server engine

=head1 SYNOPSIS

  #!/usr/bin/perl -w -T
  package MyPackage;

  use Net::Server;
  @ISA = qw(Net::Server);

  sub process_request {
     #...code...
  }

  MyPackage->run();
  exit;

=head1 OBTAINING

Visit http://seamons.com/ for the latest version.

=head1 FEATURES

 * Single Server Mode
 * Inetd Server Mode
 * Preforking Mode
 * Forking Mode
 * Multi port accepts on Single, Preforking, and Forking modes
 * User customizable hooks
 * Chroot ability after bind
 * Change of user and group after bind
 * Basic allow/deny access control
 * Customized logging (choose Syslog, log_file, or STDERR)
 * Taint clean
 * Written in Perl
 * Protection against buffer overflow
 * Clean process flow
 * Extensibility

=head1 DESCRIPTION

C<Net::Server> is an extensible, generic Perl server engine.
C<Net::Server> combines the good properties from
C<Net::Daemon> (0.34), C<NetServer::Generic> (1.03), and
C<Net::FTPServer> (1.0), and also from various concepts in
the Apache Webserver.

C<Net::Server> attempts to be a generic server as in
C<Net::Daemon> and C<NetServer::Generic>.  It includes with
it the ability to run as an inetd process
(C<Net::Server::INET>), a single connection server
(C<Net::Server> or C<Net::Server::Single>), a forking server
(C<Net::Server::Fork>), or as a preforking server
(C<Net::Server::PreFork>).  In all but the inetd type, the
server provides the ability to connect to one or to multiple
server ports.

C<Net::Server> uses ideologies of C<Net::FTPServer> in order
to provide extensibility.  The additional server types are
made possible via "personalities" or sub classes of the
C<Net::Server>.  By moving the multiple types of servers out of
the main C<Net::Server> class, the C<Net::Server> concept is
easily extended to other types (in the near future, we would
like to add a "Thread" personality).

C<Net::Server> borrows several concepts from the Apache
Webserver.  C<Net::Server> uses "hooks" to allow custom
servers such as SMTP, HTTP, POP3, etc. to be layered over
the base C<Net::Server> class.  In addition the
C<Net::Server::PreFork> class borrows concepts of
min_start_servers, max_servers, and min_waiting servers.
C<Net::Server::PreFork> also uses the concept of an flock
serialized accept when accepting on multiple ports (PreFork
can choose between flock, IPC::Semaphore, and pipe to control
serialization).

=head1 PERSONALITIES

C<Net::Server> is built around a common class (Net::Server)
and is extended using sub classes, or C<personalities>.
Each personality inherits, overrides, or enhances the base
methods of the base class.

Included with the Net::Server package are several basic
personalities, each of which has their own use.

=over 4

=item Fork

Found in the module Net/Server/Fork.pm (see
L<Net::Server::Fork>).  This server binds to one or more
ports and then waits for a connection.  When a client
request is received, the parent forks a child, which then
handles the client and exits.  This is good for moderately
hit services.

=item INET

Found in the module Net/Server/INET.pm (see
L<Net::Server::INET>).  This server is designed to be used
with inetd.  The C<pre_bind>, C<bind>, C<accept>, and
C<post_accept> are all overridden as these services are
taken care of by the INET daemon.

=item MultiType

Found in the module Net/Server/MultiType.pm (see
L<Net::Server::MultiType>).  This server has no server
functionality of its own.  It is designed for servers which
need a simple way to easily switch between different
personalities.  Multiple C<server_type> parameters may be
given and Net::Server::MultiType will cycle through until it
finds a class that it can use.

=item PreFork

Found in the module Net/Server/PreFork.pm (see
L<Net::Server::PreFork>).  This server binds to one or more
ports and then forks C<min_servers> child process.  The
server will make sure that at any given time there are
C<spare_servers> available to receive a client request, up
to C<max_servers>.  Each of these children will process up
to C<max_requests> client connections.  This type is good
for a heavily hit site, and should scale well for most
applications.  Multi port accept is accomplished using
either flock, IPC::Semaphore, or pipe to serialize the
children.  Serialization may also be switched on for single
port in order to get around an OS that does not allow multiple
children to accept at the same time.  For a further 
discussion of serialization see L<Net::Server::PreFork>.

=item Single

All methods fall back to Net::Server.  This personality is
provided only as parallelism for Net::Server::MultiType.

=back

C<Net::Server> was partially written to make it easy to add
new personalities.  Using separate modules built upon an
open architecture allows for easy addition of new features,
a separate development process, and reduced code bloat in
the core module.

=head1 SAMPLE CODE

The following is a very simple server.  The main
functionality occurs in the process_request method call as
shown below.  Notice the use of timeouts to prevent Denial
of Service while reading.  (Other examples of using
C<Net::Server> can, or will, be included with this distribution).  

  #!/usr/bin/perl -w -T
  #--------------- file test.pl ---------------

  package MyPackage;

  use strict;
  use vars qw(@ISA);
  use Net::Server::PreFork; # any personality will do

  @ISA = qw(Net::Server::PreFork);

  MyPackage->run();
  exit;

  ### over-ridden subs below

  sub process_request {
    my $self = shift;
    eval {

      local $SIG{ALRM} = sub { die "Timed Out!\n" };
      my $timeout = 30; # give the user 30 seconds to type a line

      my $previous_alarm = alarm($timeout);
      while( <STDIN> ){
        s/\r?\n$//;
        print "You said \"$_\"\r\n";
        alarm($timeout);
      }
      alarm($previous_alarm);

    };

    if( $@=~/timed out/i ){
      print STDOUT "Timed Out.\r\n";
      return;
    }

  }

  1;

  #--------------- file test.pl ---------------

Playing this file from the command line will invoke a
Net::Server using the PreFork personality.  When building a
server layer over the Net::Server, it is important to use
features such as timeouts to prevent Denial of Service
attacks.

=head1 ARGUMENTS

There are four possible ways to pass arguments to
Net::Server.  They are I<passing on command line>, I<using a
conf file>, I<passing parameters to run>, or I<using a
pre-built object to call the run method>.

Arguments consist of key value pairs.  On the commandline
these pairs follow the POSIX fashion of C<--key value> or
C<--key=value>, and also C<key=value>.  In the conf file the
parameter passing can best be shown by the following regular
expression: ($key,$val)=~/^(\w+)\s+(\S+?)\s+$/.  Passing
arguments to the run method is done as follows:
C<Net::Server->run(key1 => 'val1')>.  Passing arguments via
a prebuilt object can best be shown in the following code:

  #!/usr/bin/perl -w -T
  #--------------- file test2.pl ---------------
  package MyPackage;
  use strict;
  use vars (@ISA);
  use Net::Server;
  @ISA = qw(Net::Server);

  my $server = bless {
    key1 => 'val1',
    }, 'MyPackage';

  $server->run();
  #--------------- file test.pl ---------------

All five methods for passing arguments may be used at the
same time.  Once an argument has been set, it is not over
written if another method passes the same argument.  C<Net::Server>
will look for arguments in the following order: 

  1) Arguments contained in the prebuilt object.
  2) Arguments passed on command line.
  3) Arguments passed to the run method.
  4) Arguments passed via a conf file.
  5) Arguments set in the configure_hook.

Key/value pairs used by the server are removed by the
configuration process so that server layers on top of
C<Net::Server> can pass and read their own parameters.
Currently, Getopt::Long is not used. The following arguments
are available in the default C<Net::Server> or
C<Net::Server::Single> modules.  (Other personalities may
use additional parameters and may optionally not use
parameters from the base class.)

  Key               Value                    Default
  conf_file         "filename"               undef

  log_level         0-4                      2
  log_file          (filename|Sys::Syslog)   undef
  pid_file          "filename"               undef

  syslog_logsock    (unix|inet)              unix
  syslog_ident      "identity"               "net_server"
  syslog_logopt     (cons|ndelay|nowait|pid) pid
  syslog_facility   \w+                      daemon

  port              \d+                      20203
  host              "host"                   "*"
  proto             "proto"                  "tcp"
  listen            \d+                      10

  reverse_lookups   1                        undef
  allow             /regex/                  none
  deny              /regex/                  none

  chroot            "directory"              undef
  user              (uid|username)           "nobody"
  group             (gid|group)              "nobody"
  background        1                        undef
  setsid            1                        undef

=over 4

=item conf_file

Filename from which to read additional key value pair arguments
for starting the server.  Default is undef.

=item log_level

Ranges from 0 to 4 in level.  Specifies what level of error
will be logged.  "O" means logging is off.  "4" means very
verbose.  These levels should be able to correlate to syslog
levels.  Default is 2.  These levels correlate to syslog levels
as defined by the following key/value pairs: 0=>'err', 
1=>'warning', 2=>'notice', 3=>'info', 4=>'debug'.

=item log_file

Name of log file to be written to.  If no name is given and 
hook is not overridden, log goes to STDERR.  Default is undef.
If the magic name "Sys::Syslog" is used, all logging will
take place via the Sys::Syslog module.  If syslog is used
the parameters C<syslog_logsock>, C<syslog_ident>, and
C<syslog_logopt>,and C<syslog_facility> may also be defined.

=item pid_file

Filename to store pid of parent process.  Generally applies
only to forking servers.  Default is none (undef).

=item syslog_logsock

Only available if C<log_file> is equal to "Sys::Syslog".  May
be either "unix" of "inet".  Default is "unix".  
See L<Sys::Syslog>.

=item syslog_ident

Only available if C<log_file> is equal to "Sys::Syslog".  Id 
to prepend on syslog entries.  Default is "net_server".
See L<Sys::Syslog>.

=item syslog_logopt

Only available if C<log_file> is equal to "Sys::Syslog".  May
be either zero or more of "pid","cons","ndelay","nowait".  
Default is "pid".  See L<Sys::Syslog>.

=item syslog_facility

Only available if C<log_file> is equal to "Sys::Syslog".
See L<Sys::Syslog> and L<syslog>.  Default is "daemon".

=item port

Local port on which to bind.  If low port, process must start
as root.  If multiple ports are given, all will be bound at 
server startup.  May be of the form C<host:port/proto>,
C<host:port>, or C<port>, where I<host> represents a hostname
residing on the local box, where I<port> represents either the
number of the port (eg. "80") or the service designation (eg.
"http"), and where I<proto> represents the protocol to be used.
If the protocol is not specified, I<proto> will default to the 
C<proto> specified in the arguments.  If C<proto> is not specified
there it will default to "tcp".  If I<host> is not specified, 
I<host> will default to C<host> specified in the arguments.  If 
C<host> is not specified there it will default to "*".
Default port is 20203.

=item host

Local host or addr upon which to bind port.  If a value of '*' is
given, the server will bind that port on all available addresses
on the box.  See L<IO::Socket>.

=item proto

Protocol to use when binding ports.  See L<IO::Socket>.

=item listen

  See L<IO::Socket>

=item reverse_lookups

Specify whether to lookup the hostname of the connected IP.
Information is cached in server object under C<peerhost>
property.  Default is to not use reverse_lookups (undef).

=item allow/deny

May be specified multiple times.  Contains regex to compare
to incoming peeraddr or peerhost (if reverse_lookups has
been enabled).  If allow or deny options are given, the
incoming client must match an allow and not match a deny or
the client connection will be closed.  Defaults to empty
array refs.

=item chroot

Directory to chroot to after bind process has taken place
and the server is still running as root.  Defaults to 
undef.

=item user

Userid or username to become after the bind process has
occured.  Defaults to "nobody."  If you would like the
server to run as root, you will have to specify C<user>
equal to "root".

=item group

Groupid or groupname to become after the bind process has
occured.  Defaults to "nobody."  If you would like the
server to run as root, you will have to specify C<group>
equal to "root".

=item background

Specifies whether or not the server should fork after the
bind method to release itself from the command line.
Defaults to undef.  Process will also background if
C<setsid> is set.

=item setsid

Specifies whether or not the server should fork after the
bind method to release itself from the command line and then
run the C<POSIX::setsid()> command to truly daemonize.
Defaults to undef.

=back

=head1 PROPERTIES

All of the C<ARGUMENTS> listed above become properties of
the server object under the same name.  These properties, as
well as other internal properties, are available during
hooks and other method calls.

The structure of a Net::Server object is shown below:

  $self = bless( {
                   'server' => {
                                 'key1' => 'val1',
                                 # more key/vals
                               }
                 }, 'Net::Server' );

This structure was chosen so that all server related
properties are grouped under a single key of the object
hashref.  This is so that other objects could layer on top
of the Net::Server object class and still have a fairly
clean namespace in the hashref.

You may get and set properties in two ways.  The suggested
way is to access properties directly via

 my $val = $self->{server}->{key1};

Accessing the properties directly will speed the
server process.  A second way has been provided for object
oriented types who believe in methods.  The second way
consists of the following methods:

  my $val = $self->get_property( 'key1' );
  my $self->set_property( key1 => 'val1' );

Properties are allowed to be changed at any time with
caution (please do not undef the sock property or you will
close the client connection).

=head1 CONFIGURATION FILE

C<Net::Server> allows for the use of a configuration file to
read in server parameters.  The format of this conf file is
simple key value pairs.  Comments and white space are
ignored.

  #-------------- file test.conf --------------

  ### user and group to become
  user        somebody
  group       everybody

  ### logging ?
  log_file    /var/log/server.log
  log_level   3
  pid_file    /tmp/server.pid

  ### optional syslog directive
  ### used in place of log_file above
  #log_file       Sys::Syslog
  #syslog_logsock unix
  #syslog_ident   myserver
  #syslog_logopt  pid|cons

  ### access control
  allow       .+\.(net|com)
  allow       domain\.com
  deny        a.+

  ### background the process?
  background  1

  ### ports to bind (this should bind
  ### 127.0.0.1:20205 and localhost:20204)
  host        127.0.0.1
  port        localhost:20204
  port        20205

  ### reverse lookups ?
  # reverse_lookups on
 
  #-------------- file test.conf --------------

=head1 PROCESS FLOW

The process flow is written in an open, easy to
override, easy to hook, fashion.  The basic flow is
shown below.

  $self->configure_hook;

  $self->configure(@_);

  $self->post_configure;

  $self->post_configure_hook;

  $self->pre_bind;

  $self->bind;

  $self->post_bind_hook;

  $self->post_bind;

  $self->pre_loop_hook;

  $self->loop;

  ### routines inside a standard $self->loop
  # $self->accept;
  # $self->run_client_connection;
  # $self->done;

  $self->pre_server_close_hook;

  $self->server_close;

The server then exits.

During the client processing phase
(C<$self-E<gt>run_client_connection>), the following
represents the program flow:

  $self->post_accept;

  $self->get_client_info;

  $self->post_accept_hook;

  if( $self->allow_deny

      && $self->allow_deny_hook ){
    
    $self->process_request;

  }else{

    $self->request_denied_hook;

  }

  $self->post_process_request_hook;

  $self->post_process_request;

The process then loops and waits for the next
connection.  For a more in depth discussion, please
read the code.


=head1 HOOKS

C<Net::Server> provides a number of "hooks" allowing for
servers layered on top of C<Net::Server> to respond at
different levels of execution.

=over 4

=item C<$self-E<gt>configure_hook()>

This hook takes place immediately after the C<-E<gt>run()>
method is called.  This hook allows for setting up the
object before any built in configuration takes place. 
This allows for custom configurability.

=item C<$self-E<gt>post_configure_hook()>

This hook occurs just after the reading of configuration
parameters and initiation of logging and pid_file creation.
It also occurs before the C<-E<gt>pre_bind()> and
C<-E<gt>bind()> methods are called.  This hook allows for
verifying configuration parameters.

=item C<$self-E<gt>post_bind_hook()>

This hook occurs just after the bind process and just before
any chrooting, change of user, or change of group occurs.
At this point the process will still be running as the user
who started the server.

=item C<$self-E<gt>pre_loop_hook()>

This hook occurs after chroot, change of user, and change of
group has occured.  It allows for preparation before looping
begins.

=item C<$self-E<gt>post_accept_hook()>

This hook occurs after a client has connected to the server.
At this point STDIN and STDOUT are mapped to the client
socket.  This hook occurs before the processing of the
request.

=item C<$self-E<gt>allow_deny_hook()>

This hook allows for the checking of ip and host information
beyond the C<$self-E<gt>allow_deny()> routine.  If this hook
returns 1, the client request will be processed,
otherwise, the request will be denied processing.

=item C<$self-E<gt>request_denied_hook()>

This hook occurs if either the C<$self-E<gt>allow_deny()> or
C<$self-E<gt>allow_deny_hook()> have taken place.

=item C<$self-E<gt>post_process_request_hook()>

This hook occurs after the processing of the request, but
before the client connection has been closed.

=item C<$self-E<gt>pre_server_close_hook()>

This hook occurs before the server begins shutting down.

=item C<$self-E<gt>write_to_log_hook>

This hook handles writing to log files.  The default hook
is to write to STDERR, or to the filename contained in
the parameter C<log_file>.  The arguments passed are a
log level of 0 to 4 (4 being very verbose), and a log line.
If log_file is equal to "Sys::Syslog", then logging will
go to Sys::Syslog and will bypass the write_to_log_hook.

=item C<$self-E<gt>fatal_hook>

This hook occurs when the server has encountered an
unrecoverable error.  Arguments passed are the error
message, the package, file, and line number.  The hook
may close the server, but it is suggested that it simply
return and use the built in shut down features.

=back

=head1 TO DO

There are several tasks to perform before the alpha label
can be removed from this software:

=over 4

=item Use It

The best way to further the status of this project is to use
it.  There are immediate plans to use this as a base class
in implementing some mail servers and banner servers on a
high hit site.

=item Thread Personality

Some servers offer a threaded server.  Create
C<Net::Server::Thread> as a new personality.

=item Other Personalities

Explore any other personalities

=item Sig Handling

Solidify which signals are handled by base class.  Possibly
catch more that are ignored currently.

=item C<HUP>

Allow for a clean hup allowing for re-exec and re-read of
configuration files.  This includes multiport mode.

=item Net::HTTPServer, etc

Create various types of servers.  Possibly, port exising
servers to user Net::Server as a base layer.

=item More documentation

Show more examples and explain process flow more.

=back

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

=head1 THANKS

Thanks to Rob Brown <rbrown@about-inc.com> for help with
miscellaneous concepts such as tracking down the
serialized select via flock ala Apache and the reference
to IO::Select making multiport servers possible.  

Thanks to Jonathan J. Miner <miner@doit.wisc.edu> for
patching a blatant problem in the reverse lookups.

Thanks to Bennett Todd <bet@rahul.net> for
pointing out a problem in Solaris 2.5.1 which does not 
allow multiple children to accept on the same port at
the same time.  Also for showing some sample code
from Viktor Duchovni which now represents the semaphore
option of the serialize argument in the PreFork server.

=head1 SEE ALSO

Please see also
L<Net::Server::Fork>,
L<Net::Server::INET>,
L<Net::Server::PreFork>,
L<Net::Server::MultiType>,
L<Net::Server::Single>

=head1 COPYRIGHT

  Copyright (C) 2001, Paul T Seamons
                      paul@seamons.com
                      http://seamons.com/
  
  This package may be distributed under the terms of either the
  GNU General Public License 
    or the
  Perl Artistic License

  All rights reserved.

=cut
