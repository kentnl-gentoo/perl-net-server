BEGIN { $| = 1; print "1..4\n"; }

### load the module
END {print "not ok 1\n" unless $loaded;}
use Net::Server::Fork;
$loaded = 1;
print "ok 1\n";

### test fork - don't care about platform
my $fork = 0;
eval {
  my $pid = fork;
  die unless defined $pid; # can't fork
  exit unless $pid;        # can fork, exit child
  $fork = 1;
  print "ok 2\n";
};
print "not ok 2\n" if $@;

### become a new type of server
package Net::Server::Test;
@ISA = qw(Net::Server::Fork);
use IO::Socket;
local $SIG{ALRM} = sub { die };
my $alarm = 15;

### test and setup pipe
local *READ;
local *WRITE;
my $pipe = 0;
eval {

  ### prepare pipe
  pipe( READ, WRITE );
  READ->autoflush(  1 );
  WRITE->autoflush( 1 );

  ### test pipe
  print WRITE "hi\n";
  die unless scalar(<READ>) eq "hi\n";

  $pipe = 1;
  print "ok 3\n";

};
print "not ok 3\n" if $@;


### extend the accept method a little
### we will use this to signal that
### the server is ready to accept connections
sub accept {
  my $self = shift;
  
  print WRITE "ready!\n";

  return $self->SUPER::accept();
}

### start up a vanilla server and connect to it
if( $fork && $pipe ){

  eval {
    alarm $alarm;

    my $pid = fork;

    ### can't proceed unless we can fork
    die unless defined $pid;

    ### parent does the client
    if( $pid ){

      <READ>; ### wait until the child writes to us

      ### connect to child
      my $remote = IO::Socket::INET->new(PeerAddr => 'localhost',
                                         PeerPort => 20203,
                                         Proto    => 'tcp');
      die unless defined $remote;

      ### sample a line
      my $line = <$remote>;
      die unless $line =~ /Net::Server/;

      ### shut down the server
      print $remote "exit\n";
      print "ok 4\n";

    ### child does the server
    }else{

      close STDERR;
      Net::Server::Test->run();
      exit;

    }

    alarm 0;
  };
  print "not ok 4\n" if $@;

}else{
  print "not ok 4\n";
}


