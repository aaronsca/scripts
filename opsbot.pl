#!/usr/bin/env perl

# proof of concept irc bot to automatically grant operator privileges
# to specific nicks, some "fun" commands based on random supybot plugins
# and some basic network diagnostic commands.

use strict;
use warnings;
use POSIX qw(setsid);

my $debug       = $ARGV[0] && $ARGV[0] =~ /\A\-(d|\-debug)\z/o
                ? shift(@ARGV) : q{};

unless (scalar(@ARGV) == 4) {
    die "$0 [-d|--debug] hostname channel bot_nick ops_file\n";
}
my($hostname, $channel, $bot_nick, $ops_file) = @ARGV;
my $bot         = IRC::Simple::OpsBot->new(
    hostname    => $hostname,
    channel     => $channel,
    nick        => $bot_nick,
    ops_file    => $ops_file,
    debug       => $debug
);
if ($debug) {
    use IO::Handle;
    STDERR->autoflush(1);
    STDOUT->autoflush(1);
}
else {
    my $pid;
    $SIG{CHLD}  = 'IGNORE';
    if ($pid    = fork()) { # parent
        exit(0);
    }
    elsif ($pid == 0) {     # child
        open(STDIN, '/dev/null');
        open(STDOUT, '+>/dev/null');
        open(STDERR, '+>/dev/null');
        setsid;
        $SIG{HUP} = 'IGNORE';
    }
    else {
        $bot->log_fatal("fork failed: $!");
    }
}

# main loop
while (my $line = $bot->getline) {

    # something said in channel
    if ($line =~ /\A:([^!]+)!\S+ PRIVMSG \S+ :(.*)\z/o) {
        my $nick    = $1;
        my $mesg    = $2;

        # someone mentioned bot
        if ($mesg =~ /$bot_nick:/o) {
            if ($mesg =~ /(screw|fuck) you/io) {
                $bot->say('buy me dinner first?');
            }
            elsif ($mesg =~ /(fuck|piss) off/io
                || $mesg =~ /die in a fire/io
                || $mesg =~ /diaf/io
                || $mesg =~ /get lost/io
                || $mesg =~ /go away/io
            ) {
                $bot->quit('as you wish');
                $bot->log_fatal($line);
            }
            elsif ($mesg =~ /you suck/ || $mesg =~ /\!\z/o) {
                $bot->say(
                    'yeah? well, you know, that\'s just like your opinion, man.'
                );
            }
            elsif ($mesg =~ /\?\z/o) {
                $bot->act('shrugs');
            }
            else {
                $bot->act('stares blankly');
            }
            next;
        }
    }

    # let bot do its thing
    $bot->process($line);
}

# inline packages to allow single source script
{
    package IRC::Simple;

    use strict;
    use warnings;
    use utf8;
    use IO::Socket::INET;
    use Encode;
    use constant {
        CRLF            => "\015\012",
        SOH             => "\001",
        RPL_MYINFO      => 4,
        RPL_NAMREPLY    => 353,
        RPL_ENDOFNAMES  => 366,
        RPL_ENDOFMOTD   => 376
    };

    sub nick            { shift->_accessor(@_) }
    sub sock            { shift->_accessor(@_) }
    sub debug           { shift->_accessor(@_) }
    sub channel         { shift->_accessor(@_) }
    sub basename        { shift->_accessor(@_) }
    sub _login_opt      { shift->_accessor(@_) }
    sub _accessor       {
        my $self        = $_[0];
        my $key         = (caller(1))[3];
        $key            =~ s/.*:://;

        return scalar(@_) == 2       ? $self->{$key} = $_[1]
             : exists($self->{$key}) ? $self->{$key}
             : undef
    }

    sub new {
        my $class       = shift(@_);
        my $self        = bless { }, $class;
        my %opt         = @_;

        foreach my $key (qw(hostname channel nick)) {
            unless ($opt{$key}) {
                $self->log_fatal("$key option expected");
            }
        }
        if ($opt{'hostname'} =~ /\A([^:]+):(\d+)\z/o) {
            $opt{'hostname'} = $1;
            $opt{'port'}     = $2;
        }

        my $basename    = $0;
        $basename       =~ s/\A.*\///go;
        $opt{'debug'}   = $opt{'debug'} ? 1 : 0;
        $opt{'port'}  //= 6667;
        $opt{'pass'}  //= q{};
        $opt{'user'}  //= $opt{'nick'};
        $opt{'name'}  //= $opt{'nick'};

        foreach my $key (qw(channel nick debug)) {
            $self->$key(delete( $opt{$key} ));
        }
        $self->_login_opt(\%opt);
        $self->basename($basename);

        return $self->_login;
    }

    sub _login {
        my $self    = $_[0];
        my $opt     = $self->_login_opt;
        my $exp     = 0;
        
        $self->is_op(0);

        if ($self->sock) {
            eval { $self->sock->close }
        }
        while (1) {
            my $sock    = IO::Socket::INET->new(
                PeerPort    => $opt->{'port'},
                PeerAddr    => $opt->{'hostname'},
                Proto       => 'tcp'
            );
            unless (ref($sock)) {
                $self->log_error("$opt->{'hostname'}:$opt->{'port'} $!");
                sleep(2 ** ( $exp > 10 ? $exp = 0 : $exp++));
                next;
            }
            $self->sock($sock);
            last;
        }
        $self->send("PASS $opt->{'pass'}") if $opt->{'pass'};
        $self->send("NICK " . $self->nick);
        $self->send("USER $opt->{'user'} 8 * :$opt->{'name'}");

        while (my $line = $self->getline) {
            if ($line =~ /\A\S+ (\d+) /o) {
                if ($1 == RPL_MYINFO || $1 == RPL_ENDOFMOTD) {
                    last;
                }
            }
            if ($line =~ /\AERROR/o) {
                $self->log_fatal($line);
            }
        }
        $self->join( $self->channel );

        return $self;
    }

    sub send {
        my $self    = $_[0];
        my $data    = Encode::encode_utf8($_[1] // q{});

        $self->log_send($data);
        $self->sock->print($data, CRLF);
    }

    sub getline {
        my $self    = $_[0];

        while (1) {
            my $line    = $self->sock->getline;
            unless (defined($line)) {
                $self->_login;
                next;
            }
            $line       =~ s/\r\n\z//go;
            $self->log_recv($line);

            if ($line   =~ /\APING (\S+)/o) {
                $self->send('PONG ' . $1);
                next;
            }
            if ($line   =~ /\A\S+ (\d+) /o) {
                if ($1 >= 400 && $1 < 600) {
                    $self->log_fatal($line);
                }
            }

            return Encode::decode_utf8($line);
        }
    }

    sub join {
        my $self    = $_[0];
        my $channel = $_[1];

        $self->send("JOIN :$channel");

        while (my $line = $self->getline) {
            last if $line =~ /JOIN :$channel\z/io;
        }

        return $self->channel($channel);
    }

    sub part {
        my $self    = $_[0];
        my $channel = $self->channel;
        my $reason  = $_[1] // '*poof*';

        $self->send(sprintf('PART %s :%s', $self->channel, $reason));
    }

    sub quit {
        my $self    = $_[0];
        my $reason  = $_[1] // '*poof*';

        $self->send("QUIT :$reason");
    }

    sub say {
        my $self    = $_[0];
        my $mesg    = $_[1] // q{};

        if (length($mesg)) {
            $self->send(sprintf('PRIVMSG %s :%s', $self->channel, $mesg));
        }
    }

    sub act {
        my $self    = $_[0];
        my $action  = $_[1] // q{};
        
        if (length($action)) {
            $self->say(sprintf('%sACTION %s%s', SOH, $action, SOH));
        }
    }

    sub mode {
        my $self    = $_[0];
        my $mode    = $_[1];
        my $nick    = $_[2];

        $self->send(sprintf('MODE %s %s %s', $self->channel, $mode, $nick));
    }
    
    sub kick {
        my $self    = $_[0];
        my $nick    = $_[1];
        my $mesg    = $_[2] // q{};

        $self->send(sprintf('KICK %s %s :%s', $self->channel, $nick, $mesg));
    }

    sub names {
        my $self    = $_[0];
        my $channel = $self->channel;
        my $nick    = $self->nick;
        my $begin   = RPL_NAMREPLY;
        my $end     = RPL_ENDOFNAMES;
        my @name    = ();

        $self->send("NAMES $channel");

        while (my $line = $self->getline) {
            if ($line =~ /\A\S+ $begin $nick . $channel :(.*)\z/io) {
                push(@name, split(/\s+/, $1));
                next;
            }
            if ($line =~ /\A\S+ $end $nick $channel :/io) {
                last;
            }
        }

        return @name;
    }

    # assume utf8 encoded with no trailing crlf for all logging
    sub log_fatal {
        my $self    = $_[0];
        my $mesg    = $_[1];

        if (defined($mesg)) {
            $self->log_error($mesg);
        }
        exit(1);
    }

    sub log_error {
        my $self    = $_[0];
        my $mesg    = $_[1] // q{};

        if ($self->debug) {
            print STDERR time . " >!< $mesg\n";
        }
        else {
            my $prog = $self->basename;
            `logger -p user.err "$prog: $mesg" > /dev/null 2>&1`
        }
    }

    sub log_recv {
        my $self    = $_[0];
        my $mesg    = $_[1] // q{};

        if ($self->debug) {
            print STDOUT time . " <== $mesg\n";
        }
    }

    sub log_send {
        my $self    = $_[0];
        my $mesg    = $_[1] // q{};

        if ($self->debug) {
            print STDOUT time . " ==> $mesg\n";
        }
    }

    sub log_debug {
        my $self    = $_[0];
        my $mesg    = $_[1] // q{};

        if ($self->debug) {
            print STDOUT time . " <-> $mesg\n";
        }
    }
};
{
    package IRC::Simple::OpsBot;

    use strict;
    use warnings;
    use utf8;
    use Encode;
    use Socket qw();
    use IO::File;
    use constant {
        ROULETTE_SIZE  => 6,
        EIGHTBALL      => [[
            'it is possible', 'yes!', 'of course',
            'naturally', 'obviously', 'it shall be',
            'the outlook is good', 'it is so',
            'one would be wise to think so',
            'the answer is certainly yes', 'mais bien sûr!'
        ],[
            'in your dreams', 'i doubt it very much',
            'no chance', 'the outlook is poor',
            'unlikely', 'about as likely as pigs flying',
            'you\'re kidding, right?', 'no!', 'nein', 'nyet',
            'the answer is a resounding no'
        ],[
            'maybe...', 'no clue', '_i_ don\'t know',
            'the outlook is hazy, please ask again later',
            'what are you asking me for?', 'come again?',
            'you know the answer better than i',
            'the answer is def-- oooh! shiny thing!'
        ]],
        DOW             => [qw( Sun Mon Tue Wed Thu Fri Sat )],
        MON             => [qw(
            Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec
        )]
    };

    # inline packages apparently break "use parent" subclassing
    our @ISA;
    BEGIN {
        push(@ISA, qw(IRC::Simple));
    }

    sub is_op           { shift->_accessor(@_) }
    sub _ops            { shift->_accessor(@_) }
    sub _ops_mtime      { shift->_accessor(@_) }
    sub _ops_file       { shift->_accessor(@_) }
    sub _roulette_loc   { shift->_accessor(@_) }
    sub _roulette_cur   { shift->_accessor(@_) }

    sub new {
        my $class   = shift;
        my %opt     = @_;
        my $self    = $class->SUPER::new(%opt);

        unless ($opt{'ops_file'}) {
            $self->log_fatal("ops_file option expected");
        }
        $self->_ops_file( $opt{'ops_file'} );

        return $self;
    }

    # process line from irc server
    sub process {
        my $self    = $_[0];
        my $line    = $_[1];
        my $channel = $self->channel;
        my $me      = $self->nick;

        # bot command request?
        if ($line =~ /\A:([^!]+)!\S+ PRIVMSG $channel :@(.+)\z/io) {
            my $nick    = $1;
            my @arg     = split(/\s+/, $2, 2);
            my $cmd     = 'do_' . shift(@arg);
            if ($self->can($cmd)) {
                $self->$cmd($nick, @arg);
            }
        }

        # someone joined channel or changed nick. change mode?
        elsif ($line =~ /\A:([^!]+)!\S+ JOIN :$channel/io
            || $line =~ /\A:([^!]+)!\S+ NICK :(\S+)/o
        ) {
            my $nick    = $2 ? $2 : $1;
            my $prev    = $2 ? $1 : $1;
            if ($self->is_op) {
                my $op  = $self->ops;
                if ($op->{$nick}) {
                    $self->mode('+o', $nick);
                }
                if ($op->{$prev} && !$op->{$nick}) {
                    $self->mode('-o', $nick);
                }
            }
        }

        # bot kicked out of channel
        elsif ($line =~ /\A:([^!]+)!\S+ KICK $channel $me /io) {
            $self->log_fatal($line);
        }

        # bot given operator privileges or had them taken away
        elsif ($line =~ /\A:([^!]+)!\S+ MODE $channel ([\+\-]o) $me\s*\z/io) {
            my $nick    = $1;
            my $mode    = $2;
            if ($mode eq '+o') {
                $self->is_op(1);
                $self->do_ops;
            }
            else {
                $self->is_op(0);
            }
        }

        return $line;
    }

    sub do_help {
        my $self    = $_[0];
        my $class   = ref($self) . '::';
        my @cmd     = ();

        no strict qw(refs);
        foreach my $name (keys %$class) {
            next unless $self->can($name);
            next unless $name =~ s/\Ado_//go;
            next if $name eq 'help';
            push(@cmd, '@' . $name);
        }

        $self->say('commands: ' . join(q{, }, sort @cmd));
    }

    sub _valid_fqdn_bool {
        my $fqdn    = $_[1];

        return 0 if length($fqdn) > 252;
        return 0 if $fqdn =~ /\.\./o;
        return 0 if $fqdn !~ /\A[A-Za-z0-9\.\-]+\z/o;

        foreach (split('.', $fqdn)) {
            return 0 if length($_) > 63;
            return 0 if $fqdn =~ /\A\-/o;
            return 0 if $fqdn =~ /\-\z/o;
            return 0 if $fqdn !~ /[A-Za-z]/o;
        }

        return 1;
    }

    sub _valid_ipv4_bool {
        return defined(Socket::inet_aton($_[1] // q{})) ? 1 : 0;
    }

    sub do_host {
        my($self, $nick, $arg) = @_;

        if (!defined($arg) || (
               !$self->_valid_fqdn_bool($arg)
            && !$self->_valid_ipv4_bool($arg)
            && !$self->_valid_ipv6_bool($arg)
        )) {
            return $self->can('do_ping6')
                 ? $self->say('@host {fqdn|ipv4_addr|ipv6_addr}')
                 : $self->say('@host {fqdn|ipv4_addr}')
        }
        my $ret = `host $arg 2>&1`;
        foreach my $line (split(/\n/, $ret)) {
            $self->say($line);
        }
    }
    
    sub do_ping {
        my($self, $nick, $arg) = @_;

        if (!defined($arg) || (
            !$self->_valid_fqdn_bool($arg) && !$self->_valid_ipv4_bool($arg)
        )) {
            return $self->say('@ping {fqdn|ipv4_addr}');
        }
        my $ret = `ping -c 3 -n $arg 2>&1`;
        foreach my $line (split(/\n/, $ret)) {
            $self->say($line);
        }
    }

    sub do_date {
        my($self, $nick, $arg) = @_;

        if (defined($arg)) {
            if ($arg !~ /\A\d+\z/ || $arg > 0xffffffff) {
                 return $self->say('@date [epoch_sec]');
            }
            my @t = gmtime($arg);
            return $self->say(sprintf('%s %s %02d %02d:%02d:%02d UTC %d',
                DOW->[ $t[6] ], MON->[ $t[4] ], $t[3], 
                $t[2], $t[1], $t[0], 1900 + $t[5]
            ));
        }
        else {
            return $self->say( time() );
        }
    }

    sub do_coin {
        shift->say(rand(1) < 0.5 ? 'heads' : 'tails');
    }

    sub do_eightball {
        my($self, $nick, $arg) = @_;

        if ($arg && $arg =~ /\?\z/o) {
            my $arr = EIGHTBALL->[ int(rand( scalar( @{ EIGHTBALL() } ))) ];
            $self->say($arr->[ int( rand( scalar( @$arr ))) ]);
        }
        else {
            $self->say('come again?');
        }
    }

    sub do_roulette {
        my($self, $nick, $arg) = @_;

        my $reload  = sub {
            $self->_roulette_cur(0);
            $self->_roulette_loc(int(1 + rand( ROULETTE_SIZE )));
            $self->act('reloads and spins the chambers');
        };

        if ($arg) {
            return $arg eq 'spin'
                 ? $reload->() 
                 : $self->say('@roulette [spin]');
        }
        unless ($self->_roulette_loc) {
            $reload->();
        }

        my $cur   = $self->_roulette_cur( $self->_roulette_cur + 1 );
        if ($cur == $self->_roulette_loc) {
            if ($cur == ROULETTE_SIZE) {
                $self->say("$nick: you don't come here for the huntin, do ya?");
            }
            if ($self->is_op) {
                $self->kick($nick, 'BANG!');
            }
            else {
                $self->act('*BANG*');
            }
            $reload->();
        }
        else {
            $self->act('*click*');
        }
    }

    sub do_ops {
        my $self    = $_[0];
        my $nick    = $_[1];

        unless ($self->is_op) {
            $self->say(sprintf(
                'need operator mode first. try: /mode %s +o %s',
                $self->channel, $self->nick
            ));
            return undef;
        }
        my $op      = $self->ops;
        my $count   = 0;

        foreach my $nick ($self->names) {
            next unless $op->{$nick};
            $self->mode('+o', $nick);
            $count++;
        }
        if ($nick && !$count) {
            $self->say('nothing to do');
        }

        return $count;
    }

    # parse ops_file (if needed) and return hash ref of nicks
    sub ops {
        my $self        = $_[0];
        my $op          = $self->_ops // { };
        my $ops_file    = $self->_ops_file;

        unless (-s $ops_file) {
            $self->log_error("$ops_file missing or empty");
            return $op;
        }
        my $mtime       = (stat(_))[9];
        my $ops_mtime   = $self->_ops_mtime // 0;
        if ($ops_mtime == $mtime) {
            return $op;
        }

        my $fh          = new IO::File $ops_file, 'r';
        unless (defined($fh) && ref($fh)) {
            $self->log_error("$ops_file open failed");
            return $op;
        }
        my $new_op      = { };
        while (my $line = $fh->getline) {
            if ($line =~ /\A\s*\z/o || $line =~ /\A\#/o) {
                next;
            }
            chomp($line);
            $line       = Encode::decode_utf8($line);
            my @t       = split(/\s+/, $line);
            if (scalar(@t) > 1) {
                my $num = $fh->input_line_number;
                $self->log_error("$ops_file line $num "
                    . "multiple tokens unexpected"
                );
                return $op;
            }
            $new_op->{ $t[0] }++;
        }
        $fh->close;
        $self->log_debug("$ops_file loaded ($mtime mtime):");
        $self->log_debug(join(q{, }, sort keys %$new_op));
        $self->_ops_mtime($mtime);
        $self->_ops($new_op);

        return $new_op;
    }

    # ipv6 support? 
    BEGIN {
        eval {
            require Socket6;
            *do_ping6           = \&_do_ping6;
            *_valid_ipv6_bool   = \&__valid_ipv6_bool;
        } or do {
            *_valid_ipv6_bool   = \&__valid_ipv6_noop;
        }
    }

    sub _do_ping6 {
        my($self, $nick, $arg) = @_;

        if (!defined($arg) || (
            !$self->_valid_fqdn_bool($arg) && !$self->_valid_ipv6_bool($arg)
        )) {
            return $self->say('@ping6 {fqdn|ipv6_addr}');
        }
        my $ret = `ping6 -c 3 -n $arg 2>&1`;
        foreach my $line (split(/\n/, $ret)) {
            $self->say($line);
        }
    }

    sub __valid_ipv6_bool {
        return defined(
            Socket6::inet_pton(Socket::AF_INET6, $_[1] // q{})
        ) ? 1 : 0;
    }

    sub __valid_ipv6_noop {
        return 0;
    }
};

# eof
