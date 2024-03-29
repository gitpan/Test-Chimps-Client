package Test::Chimps::Smoker;

use warnings;
use strict;

use Config;
use Cwd qw(abs_path);
use File::Path;
use File::Temp qw/tempdir/;
use Params::Validate qw/:all/;
use Test::Chimps::Smoker::Source;
use Test::Chimps::Client;
use TAP::Harness::Archive;
use YAML::Syck;

=head1 NAME

Test::Chimps::Smoker - Poll a set of repositories and run tests when they change

=head1 SYNOPSIS

    # command line tool
    chimps-smoker.pl \
        -c /path/to/configfile.yml \
        -s http://www.example.com/cgi-bin/chimps-server.pl

    # API
    use Test::Chimps::Smoker;

    my $poller = Test::Chimps::Smoker->new(
        server      => 'http://www.example.com/cgi-bin/chimps-server.pl',
        config_file => '/path/to/configfile.yml',
    );

    $poller->smoke;

=head1 DESCRIPTION

Chimps is the Collaborative Heterogeneous Infinite Monkey
Perfectionification Service.  It is a framework for storing,
viewing, generating, and uploading smoke reports.  This
distribution provides client-side modules and binaries for Chimps.

This module gives you everything you need to make your own build
slave.  You give it a configuration file describing all of your
projects and how to test them, and it will monitor the repositories,
check the projects out (and their dependencies), test them, and submit
the report to a server.

=head1 METHODS

=head2 new ARGS

Creates a new smoker object.  ARGS is a hash whose valid keys are:

=over 4

=item * config_file

Mandatory.  The configuration file describing which repositories to
monitor.  The format of the configuration is described in
L</"CONFIGURATION FILE">. File is update after each run.

=item * server

Optional.  The URI of the server script to upload the reports to.
Defaults to simulation mode when reports are sent.

=item * sleep

Optional.  Number of seconds to sleep between repository checks.
Defaults to 60 seconds.

=item * simulate [DEPRECATED]

[DEPRECATED] Just don't provide server option to enable simulation.

Don't actually submit the smoke reports, just run the tests.  This
I<does>, however, increment the revision numbers in the config
file.

=back

=cut

use base qw/Class::Accessor/;
__PACKAGE__->mk_ro_accessors(qw/server config_file simulate sleep/);
__PACKAGE__->mk_accessors(
    qw/_env_stack meta config projects iterations/);

# add a signal handler so destructor gets run
$SIG{INT} = sub {print "caught sigint.  cleaning up...\n"; exit(1)};
$ENV{PERL5LIB} = "" unless defined $ENV{PERL5LIB}; # Warnings avoidance

sub new {
    my $class = shift;
    my $obj = bless {}, $class;
    $obj->_init(@_);
    return $obj;
}

sub _init {
    my $self = shift;
    my %args = validate_with(
        params => \@_,
        spec   => {
            config_file => 1,
            server      => 0,
            simulate    => 0,
            iterations  => {
                optional => 1,
                default  => 'inf'
              },
            projects => {
                optional => 1,
                default  => 'all'
              },
            jobs => {
                optional => 1,
                type     => SCALAR,
                regex    => qr/^\d+$/,
                default  => 1,
              },
            sleep => {
                optional => 1,
                type     => SCALAR,
                regex    => qr/^\d+$/,
                default  => 60,
              },
          },
        called => 'The Test::Chimps::Smoker constructor'
      );

    foreach my $key (keys %args) {
        $self->{$key} = $args{$key};
    }

    # support simulate for a while
    delete $self->{'server'} if $args{'simulate'};

    # make it absolute so we can update it later from any dir we're in
    $self->{'config_file'} = abs_path($self->{'config_file'});

    $self->_env_stack([]);
    $self->meta({});

    $self->load_config;
}

=head2 smoke PARAMS

Calling smoke will cause the C<Smoker> object to continually poll
repositories for changes in revision numbers.  If an (actual)
change is detected, the repository will be checked out (with
dependencies), built, and tested, and the resulting report will be
submitted to the server.  This method may not return.  Valid
options to smoke are:

=over 4

=item * iterations

Specifies the number of iterations to run.  This is the number of
smoke reports to generate per project.  A value of 'inf' means to
continue smoking forever.  Defaults to 'inf'.

=item * projects

An array reference specifying which projects to smoke.  If the
string 'all' is provided instead of an array reference, all
projects will be smoked.  Defaults to 'all'.

=back

=cut

sub smoke {
    my $self = shift;
    my $config = $self->config;

    my %args = validate_with(
        params => \@_,
        spec   => {
            iterations => {
                optional => 1,
                type     => SCALAR,
                regex    => qr/^(inf|\d+)$/,
                default  => 'inf'
              },
            projects => {
                optional => 1,
                type     => ARRAYREF | SCALAR,
                default  => 'all'
              }
          },
        called => 'Test::Chimps::Smoker->smoke'
      );

    my $projects = $args{projects};
    my $iterations = $args{iterations};
    $self->_validate_projects_opt($projects);

    if ($projects eq 'all') {
        $projects = [keys %$config];
    }

    $self->_smoke_n_times($iterations, $projects);
}

sub _validate_projects_opt {
    my ($self, $projects) = @_;
    return if $projects eq 'all';

    foreach my $project (@$projects) {
        die "no such project: '$project'"
          unless exists $self->config->{$project};
    }
}

sub _smoke_n_times {
    my $self = shift;
    my $n = shift;
    my $projects = shift;

    if ($n <= 0) {
        die "Can not smoke projects a negative number of times";
    } elsif ($n eq 'inf') {
        while (1) {
            $self->_smoke_projects($projects);
            CORE::sleep $self->sleep if $self->sleep;
        }
    } else {
        for (my $i = 0; $i < $n; $i++) {
            $self->_smoke_projects($projects);
            CORE::sleep $self->sleep if $i+1 < $n && $self->sleep;
        }
    }
}

sub _smoke_projects {
    my $self = shift;
    my $projects = shift;

    foreach my $project (@$projects) {
        local $@;
        eval { $self->_smoke_once($project) };
        warn "Couldn't smoke project '$project': $@"
            if $@;
    }
}

sub _smoke_once {
    my $self = shift;
    my $project = shift;

    my $config = $self->config->{$project};
    return 1 if $config->{dependency_only};

    $self->_clone_project( $config );

    my %next = $self->source($project)->next( $config->{revision} );
    return 0 unless keys %next;

    my $revision = $next{'revision'};

    my @libs = $self->_checkout_project($config, $revision);
    unless (@libs) {
        print "Skipping report for $project revision $revision due to build failure\n";
        $self->update_revision_in_config( $project => $revision );
        return 0;
    }

    print "running tests for $project\n";
    my $test_glob = $config->{test_glob} || 't/*.t t/*/t/*.t';
    my $tmpfile = File::Temp->new( SUFFIX => ".tar.gz" );
    my $harness = TAP::Harness::Archive->new( {
            archive          => $tmpfile,
            extra_properties => {
                project   => $project,
                revision  => $revision,
                committer => $next{'committer'},
                osname    => $Config{osname},
                osvers    => $Config{osvers},
                archname  => $Config{archname},
              },
            jobs => ($config->{jobs} || $self->{jobs}),
            lib => \@libs,
        } );
    {
        # Runtests apparently grows PERL5LIB -- local it so it doesn't
        # grow without bound
        local $ENV{PERL5LIB} = $ENV{PERL5LIB};
        $harness->runtests(glob($test_glob));
    }

    $self->_clean_project( $config );

    $self->_unroll_env_stack;

    if ( my $server = $self->server ) {
        my $client = Test::Chimps::Client->new(
            archive => $tmpfile, server => $server,
        );

        print "Sending smoke report for $server\n";
        my ($status, $msg) = $client->send;
        unless ( $status ) {
            print "Error: the server responded: $msg\n";
            return 0;
        }
    }
    else {
        print "Server is not specified, don't send the report\n";
    }

    print "Done smoking revision $revision of $project\n";
    $self->update_revision_in_config( $project => $revision );
    return 1;
}

sub load_config {
    my $self = shift;

    my $cfg = $self->config(LoadFile($self->config_file));

    # update old style config file
    {
        my $found_old_style = 0;
        foreach ( grep $_->{svn_uri}, values %$cfg ) {
            $found_old_style = 1;

            $_->{'repository'} = {
                type => 'SVN',
                uri  => delete $_->{svn_uri},
            };
        }
        DumpFile($self->config_file, $cfg) if $found_old_style;
    }
    
    # store project name in its hash
    $cfg->{$_}->{'name'} = $_ foreach keys %$cfg;
}

sub update_revision_in_config {
    my $self = shift;
    my ($project, $revision) = @_;

    my $tmp = LoadFile($self->config_file);
    $tmp->{$project}->{revision} = $self->config->{$project}->{revision} = $revision;
    DumpFile($self->config_file, $tmp);
}

sub source {
    my $self = shift;
    my $project = shift;
    $self->meta->{$project}{'source'} ||= Test::Chimps::Smoker::Source->new(
            %{ $self->config->{$project}{'repository'} },
            config => $self->config->{$project},
            smoker => $self,
        );
    return $self->meta->{$project}{'source'};
}

sub _clone_project {
    my $self = shift;
    my $project = shift;

    my $source = $self->source( $project->{'name'} );
    if ( $source->cloned ) {
        chdir $source->directory
            or die "Couldn't change dir to ". $source->directory .": $!";
        return 1;
    }

    my $tmpdir = tempdir("chimps-XXXXXXX", TMPDIR => 1);
    $source->directory( $tmpdir );
    chdir $source->directory
        or die "Couldn't change dir to ". $source->directory .": $!";
    $source->clone;

    $source->cloned(1);

    return 1;
}

sub _checkout_project {
    my $self = shift;
    my $project = shift;
    my $revision = shift;

    my $source = $self->source( $project->{'name'} );
    my $co_dir = $source->directory;
    chdir $co_dir or die "Couldn't change dir to $co_dir: $!";
    $source->checkout( revision => $revision );

    my $projectdir = File::Spec->catdir($co_dir, $project->{root_dir});

    my @libs = map File::Spec->catdir($projectdir, $_),
      'blib/lib', @{ $project->{libs} || [] };
    $self->meta->{ $project->{'name'} }{'libs'} = [@libs];

    $self->_push_onto_env_stack({
        $project->{env}? (%{$project->{env}}) : (),
        'CHIMPS_'. uc($project->{'name'}) .'_ROOT' => $projectdir,
    });

    my @otherlibs;
    if (defined $project->{dependencies}) {
        foreach my $dep (@{$project->{dependencies}}) {
            print "processing dependency $dep\n";
            my $config = $self->config->{ $dep };
            $self->_clone_project( $config );
            my @deplibs = $self->_checkout_project( $config );
            if (@deplibs) {
                push @otherlibs, @deplibs;
            } else {
                print "Dependency $dep failed; aborting";
                return ();
            }
        }
    }

    my %seen;
    @libs = grep {not $seen{$_}++} @libs, @otherlibs;

    unless (chdir($projectdir)) {
        print "chdir to $projectdir failed -- check value of root_dir?\n";
        return ();
    }

    local $ENV{PERL5LIB} = join(":",@libs,$ENV{PERL5LIB});

    if (defined( my $cmd = $project->{'configure_cmd'} )) {
        my $ret = system($cmd);
        if ($ret) {
            print STDERR "Return value of $cmd from $projectdir = $ret\n"
                if $ret;
            return ();
        }
    }

    if (defined( my $cmd = $project->{'clean_cmd'} )) {
        print "Going to run project cleaner '$cmd'\n";
        my @args = (
            '--project', $project->{'name'},
            '--config', $self->config_file,
        );
        open my $fh, '-|', join(' ', $cmd, @args)
            or die "Couldn't run `". join(' ', $cmd, @args) ."`: $!";
        $self->meta->{ $project->{'name'} }->{'cleaner'} = do { local $/; <$fh> };
        close $fh;
    }
    return @libs;
}

sub _clean_project {
    my $self = shift;
    my $project = shift;

    if (defined( my $cmd = $project->{'clean_cmd'} )) {
        my @args = (
            '--project', $project->{'name'},
            '--config', $self->config_file,
            '--clean',
        );
        open my $fh, '|-', join(' ', $cmd, @args)
            or die "Couldn't run `". join(' ', $cmd, @args) ."`: $!";
        print $fh $self->meta->{ $project->{'name'} }->{'cleaner'};
        close $fh;
    }

    $self->source( $project->{'name'} )->clean;

    if (defined $project->{dependencies}) {
        foreach my $dep (@{$project->{dependencies}}) {
            $self->_clean_project( $self->config->{ $dep } );
        }
    }
}

sub _push_onto_env_stack {
    my $self = shift;
    my $vars = shift;

    my $frame = {};
    foreach my $var (keys %$vars) {
        if (exists $ENV{$var}) {
            $frame->{$var} = $ENV{$var};
        } else {
            $frame->{$var} = undef;
        }
        my $value = $vars->{$var};

        # old value substitution
        $value =~ s/\$$var/$ENV{$var}/g;

        print "setting environment variable $var to $value\n";
        $ENV{$var} = $value;
    }
    push @{$self->_env_stack}, $frame;
}

sub _unroll_env_stack {
    my $self = shift;

    while (scalar @{$self->_env_stack}) {
        my $frame = pop @{$self->_env_stack};
        foreach my $var (keys %$frame) {
            if (defined $frame->{$var}) {
                print "reverting environment variable $var to $frame->{$var}\n";
                $ENV{$var} = $frame->{$var};
            } else {
                print "unsetting environment variable $var\n";
                delete $ENV{$var};
            }
        }
    }
}

sub DESTROY {
    my $self = shift;
    $self->remove_checkouts;
}

sub remove_checkouts {
    my $self = shift;

    my $meta = $self->meta;
    foreach my $source ( grep $_, map $_->{'source'}, values %$meta ) {
        next unless my $dir = $source->directory;

        _remove_tmpdir($dir);
        $source->directory(undef);
        $source->cloned(0);
    }
}

sub _remove_tmpdir {
    my $tmpdir = shift;
    print "removing temporary directory $tmpdir\n";
    rmtree($tmpdir, 0, 0);
}

=head1 ACCESSORS

There are read-only accessors for server and config_file.

=head1 CONFIGURATION FILE

The configuration file is YAML dump of a hash.  The keys at the top
level of the hash are project names.  Their values are hashes that
comprise the configuration options for that project.

Perhaps an example is best.  A typical configuration file might
look like this:

    ---
    Some-jifty-project:
      configure_cmd: perl Makefile.PL --skipdeps && make
      dependencies:
        - Jifty
      revision: 555
      root_dir: trunk/foo
      repository:
        type: SVN
        uri: svn+ssh://svn.example.com/svn/foo
      test_glob: t/*.t t/*/*.t
    Jifty:
      configure_cmd: perl Makefile.PL --skipdeps && make
      dependencies:
        - Jifty-DBI
      revision: 1332
      root_dir: trunk
      repository:
        type: SVN
        uri: svn+ssh://svn.jifty.org/svn/jifty.org/jifty
    Jifty-DBI:
      configure_cmd: perl Makefile.PL --skipdeps && make
      env:
        JDBI_TEST_MYSQL: jiftydbitestdb
        JDBI_TEST_MYSQL_PASS: ''
        JDBI_TEST_MYSQL_USER: jiftydbitest
        JDBI_TEST_PG: jiftydbitestdb
        JDBI_TEST_PG_USER: jiftydbitest
      revision: 1358
      root_dir: trunk
      repository:
        type: SVN
        uri: svn+ssh://svn.jifty.org/svn/jifty.org/Jifty-DBI

The supported project options are as follows:

=over 4

=item * configure_cmd

The command to configure the project after checkout, but before
running tests.

=item * revision

This is the last revision known for a given project.  When started,
the poller will attempt to checkout and test all revisions (besides
ones on which the directory did not change) between this one and
HEAD.  When a test has been successfully uploaded, the revision
number is updated and the configuration file is re-written.

=item * root_dir

The subdirectory inside the repository where configuration and
testing commands should be run.

=item * repository

A hash describing repository of the project. Mandatory key is
type which must match a source class name, for example SVN or
Git. Particular source class may have more options, but at this
moment Git and SVN have only 'uri' option.

=item * env

A hash of environment variable names and values that are set before
configuration, and reverted to their previous values after the
tests have been run.  In addition, if environment variable FOO's
new value contains the string "$FOO", then the old value of FOO
will be substituted in when setting the environment variable.

Special environment variables are set in addition to described
above. For each project CHIMPS_<project name>_ROOT is set pointing
to the current checkout of the project.

=item * dependencies

A list of project names that are dependencies for the given
project.  All dependencies are checked out at HEAD, have their
configuration commands run, and all dependencys' $root_dir/blib/lib
directories are added to @INC before the configuration command for
the project is run.

=item * dependency_only

Indicates that this project should not be tested.  It is only
present to serve as a dependency for another project.

=item * test_glob

How to find all your tests, defaults to
t/*.t t/*/t/*.t

=item * libs

A list of paths, relative to the project root, which should be added
to @INC.  C<blib/lib> is automatically added, but you may need to
include C<lib> here, for instance.

=item * clean_cmd

The command to clean before or after each iteration of the project testing.
Called B<twice> before running tests and after with --config, --project
arguments and --clean argument when called for the second time after testing.

When called before testing (without --clean), state information can be printed
to STDOUT. Later when called after testing (with --clean), the state info can
be read from STDIN.

An example you can find in a tarball of this distribution - F<examples/pg_dbs_cleaner.pl>.

=back

=head1 REPORT VARIABLES

This module assumes the use of the following report variables:

    project
    revision
    committer
    duration
    osname
    osvers
    archname

=head1 AUTHOR

Zev Benjamin, C<< <zev at cpan.org> >>

=head1 BUGS

Please report any bugs or feature requests to
C<bug-test-chimps at rt.cpan.org>, or through the web interface at
L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Test-Chimps-Client>.
I will be notified, and then you'll automatically be notified of progress on
your bug as I make changes.

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc Test::Chimps::Smoker

You can also look for information at:

=over 4

=item * Mailing list

Chimps has a mailman mailing list at
L<chimps@bestpractical.com>.  You can subscribe via the web
interface at
L<http://lists.bestpractical.com/cgi-bin/mailman/listinfo/chimps>.

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/Test-Chimps-Client>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/Test-Chimps-Client>

=item * RT: CPAN's request tracker

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=Test-Chimps-Client>

=item * Search CPAN

L<http://search.cpan.org/dist/Test-Chimps-Client>

=back

=head1 COPYRIGHT & LICENSE

Copyright 2006-2009 Best Practical Solutions.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=cut

1;
