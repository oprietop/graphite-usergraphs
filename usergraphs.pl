#!/usr/bin/perl
# Check graphite metrics and supervisor status

use strict;
use warnings;
use File::Find; # find()
use YAML::Tiny; # (Load, Dump, Dumpfile)
use DBI;
use Data::Dumper;

my $results;
my %users;
my %hash     = ();
my $dir      = "/opt/graphite/storage/whisper";
my $seconds  = 21600; # 21600sec = 6 hours
my $defaults = { path      => 'collectd.windows'
               , regexp    => 'collectd.windows\.([^\.]+)\.(nic\d+_[\d\-]+)_ifentryinoctets'
               , graphname => '$1.net.$2.bits'
               , username  => 'graphite_user_name'
               , password  => 'graphite_user_pass'
               , options   => { 'areaMode'   => 'all'
                              , 'areaAlpha'  => '0.8'
                              , 'from'       => '-8hours'
                              , 'hideLegend' => 'false'
                              , 'title'      => 'Network Usage On $2'
                              , 'vtitle'     => 'tx / rx (bps)'
                              , 'lineMode'   => 'connected'
                              , 'target'     => 'aliasByNode(scaleToSeconds(nonNegativeDerivative($path.$1.$2_ifentryinoctets),8),3)'
                              }
               };

my $dbh = DBI->connect( 'dbi:mysql:dbname:dbhost.node:3306'
                      , 'dbuser'
                      , 'dbpass'
                      , { RaiseError => 1, AutoCommit => 0 }
                      ) or die "Connection Error: $DBI::errstr\n";

sub delete_usergraphs ($) {
    my $user = shift;
    if ($users{$user}) {
        my $rows = $dbh->do("delete from account_mygraph where profile_id = '$users{$user}'");
        $dbh->commit() if $rows;
        print "\tNumber of rows deleted: $rows\n";
        return 1;
    } else {
        print "\tNo user '$user' on Database.\n";
        return 0;
    }
}

sub insert_array ($) {
   my $arref = shift;
   my $sth = $dbh->prepare('insert into account_mygraph (profile_id, name, url) values (?, ?, ?)');
   my $count = 0;
   foreach my $refmet (@{ $arref }) {
       $count ++;
       print "\r\t$count insertions... ";
       $sth->execute($users{$refmet->{USER}}, $refmet->{NAME}, $refmet->{URL});
   }
   print "Commiting... ";
   $dbh->commit();
   print "OK!\n";
}

# Populate our hash with the wsp files and his access time.
sub wanted {
    my $file = $File::Find::name;
    return unless -f $file;
    my @stats = stat($file); # http://perldoc.perl.org/functions/stat.html
    my $atime = time()-$stats[9];
    if (my ($path) = $file =~ m<$dir/(.+?)\.wsp$>) {
        $path =~ s/\//\./g;
        return if     $path =~ /graphite/;
        $hash{$path} = $atime if $atime < $seconds;
    }
}

sub find_yaml {
    my $file = $File::Find::name;
    return unless -f $file;
    if ($file =~ m<y(?:|a)ml$>) {
        print "Reading '$file'... ";
        my @graphs = @{ YAML::Tiny->read( $file ) };
        print "Got ", scalar @graphs, " usergraph definitions.\n";
        foreach my $gref (@graphs) {
            $gref = { %{ $defaults }, %{ $gref } };
            parsegref($gref);
        }
    }
}

sub parsegref ($) {
    my $graph   = shift;

    # Merge over the defaults options from our $default hashref.
    $graph->{options} = { %{ $defaults->{options} }, %{ $graph->{options} } };

    # Resolve the $path variable on the regexp.
    my $regexp = $graph->{regexp};
    $regexp =~ s/\$path/$graph->{path}/g;

    my %seen = ();
    foreach my $key ( sort keys %hash ) {
        if (my @matches = ($key =~ qr{$regexp} )) {

            # Avoid duplicate results.
            my $matchstr = join ('_', @matches)."\n";
            $seen{$matchstr}++;
            next if $seen{$matchstr} > 1;

            # Create a hash with the matches array to work with.
            my %matches = map { ($_+1) => $matches[$_] } 0..($#matches);
            $matches{path} = $graph->{path};

            # Build the url string.
            my $url = '/render/?';
            foreach my $type (sort keys %{ $graph->{options} }) {
                my ($key, $value) = ($type, $graph->{options}->{$type});
                $key = 'target' if $key =~ /target/;
                # Resolve variables on the value string
                $value =~ s/\$([a-zA-Z0-9\{\}]+)/$matches{${1}}/g;
                $url .= "$key=$value&";
            }

            # Resolve variables on the graphname string
            my $graphname = $graph->{graphname};
            $graphname =~ s/\$([a-zA-Z0-9\{\}]+)/$matches{${1}}/g;

            push (@{ $results->{$graph->{username}} }, { 'URL'  => $url
                                                       , 'NAME' => $graphname
                                                       , 'USER' => $graph->{username}
                                                       }
                 );
        }
    }
}

# Populate a hash with the mappings from the user_id and graph ids.
my %idmaps = map { $_->[0], $_->[1] } @{ $dbh->selectall_arrayref("select user_id,id from account_profile") };

# Populate a hash with the user -> graph_id relation;
%users = map { $_->[0], $idmaps{$_->[1]} } @{ $dbh->selectall_arrayref("select username,id from auth_user") };

# Print the users we found.
my $dbusers = scalar keys %users;
print "Got $dbusers users on the DB.\n";
die unless $dbusers;
print Dumper \%users;

find (\&wanted, $dir);

print "Found '", scalar keys %hash, "' metrics on '$dir'\n";

find (\&find_yaml, $ENV{PWD});

foreach my $user (keys %{ $results }) {
    print "# $user\n";
    print "\tDeleting usergraphs for '$user'.\n";
    delete_usergraphs($user) ? insert_array($results->{$user}) : print "\tSkippping...\n";
}
