#! /usr/bin/env perl

# Copyright © 2017 Modell Aachen GmbH

use strict;
use warnings;
no warnings 'recursion';

use FindBin ();
$FindBin::Bin =~ /^(.*)$/;
my $bin = $1;

use lib "$FindBin::Bin/../bin";
use lib "$FindBin::Bin/../lib";

use Foswiki;
use Foswiki::Func   ();

use JSON              ;
use Getopt::Long    ();
use Pod::Usage      ();
use File::Spec        ;
use File::Basename    ;
use Time::Piece     ();

use lib "$FindBin::Bin/../lib/Foswiki/Plugins";

our %control = (
    debug => 0,
    configfile => "customization_definition.json",
    config => undef,
    csvfile => undef
);

init();


sub init{

    Getopt::Long::GetOptions(
        'debug'  => sub { $control{debug} = 1 },
        'c=s' => \$control{configfile},
        'o=s' => \$control{csvfile},
        'help' => sub{
            Pod::Usage::pod2usage( -exitstatus => 0, -verbose => 2  );
        }
    );

    _getJSONConfig($control{configfile});

    die("Import of json file failed: no valid definition, aborting.") unless defined $control{config};

    my $prefix = Time::Piece::localtime->strftime('%y%m%d');
    my $suffix = $control{config}->{outputsuffix} || "Customer_Overview_Customizing";
    $control{csvfile} = $prefix.$suffix.".csv" unless defined $control{csvfile};

    my @header = ( $control{config}->{columntitles} );
    _writeCsv(0, \@header );

    evaluateSitePrefs();
    evaluatePlugins();
    evaluateFiles();
    return 1;
}


sub debug{
    print @_, "\n" if $control{debug};
}


sub evaluatePlugins {
    my $pluginsRef = $Foswiki::cfg{Plugins};
    my $pluginsDir = File::Spec->catdir( '..','lib','Foswiki','Plugins');
    my @enabledPlugins = grep { ( ref( $pluginsRef->{$_} ) eq 'HASH' ) && defined $pluginsRef->{$_}->{Enabled} && ( $pluginsRef->{$_}->{Enabled} eq 1) } keys %{ $pluginsRef };

    foreach( @enabledPlugins ){
        my $path = File::Spec->catfile($pluginsDir, "$_.pm");
        warn("missing pm file for $_") unless -e $path;
    }

    my @pluginConfig = grep { $_->{"type"} eq 'plugin' } @{ $control{config}->{rules} };
    my @standardPlugins = @{ $pluginConfig[0]->{"standard"} };
    my @customPlugins = grep {my $temp = $_; ! grep($_ eq $temp, @standardPlugins)} @enabledPlugins;
    my %ticketPlugins = ();
    my $releaseString;

    $SIG{__WARN__} = sub
    {
        my $warning = shift;
        warn $warning unless $warning =~ /Subroutine .* redefined at/;
    };

    foreach ( @enabledPlugins ){
        no strict 'refs';
        eval "use $_ ()" unless ${'Foswiki::Plugins::'.$_.'::RELEASE'};
        $releaseString = ${'Foswiki::Plugins::'.$_.'::RELEASE'} || "";
        $ticketPlugins{$_} = $releaseString unless $releaseString !~ /^\d{2}\s[a-zA-Z]{3}\s\d{4}$/ ;
    }

    @customPlugins =  map{ $_.","."Plugin (Community)".",".$pluginsDir."$_.pm" } grep {my $temp = $_; ! grep($_ eq $temp, keys %ticketPlugins)} @customPlugins;
    my @ticketPluginsOutput = sort map{ $_.","."Plugin (Ticketbranch: ".$ticketPlugins{$_}."),".$pluginsDir."$_.pm" } keys %ticketPlugins;
    _writeCsv(1,\@customPlugins);
    _writeCsv(1,\@ticketPluginsOutput);
}


sub evaluateFiles {

    my @fileRules = grep { $_->{"type"} eq 'file' } @{ $control{config}->{rules} };
    my $dirHandle;
    my @allFiles;

    foreach (@fileRules) {
        my @customFiles;
        my $path = $_->{"path"};
        my $pattern = $_->{"name"} ;
        my $outputtype = $_->{"outputtype"} || "custom file";
        wildcardReplacement(\$pattern);
        my $filetypePattern = defined $_->{"filetype"} && @{ $_->{"filetype"} } ? join("|", @{ $_->{"filetype"} }) : ".*"; # filenames to match
        $filetypePattern =~ s/\.//g; # remove dot before extension
        wildcardReplacement(\$filetypePattern);
        my $ignorePattern = join("|", @{ $_->{"ignore"}->{"name"} } ); # filenames to ignore
        my $ignorePatternFiletype = join("|", @{ $_->{"ignore"}->{"filetype"} } );
        wildcardReplacement(\$ignorePattern);
        my $ignoreSubDirPattern = join( "|", @{ $_->{"ignore"}->{"subpath"} } ); # sub directories to skip
        wildcardReplacement(\$ignoreSubDirPattern);

        @allFiles = grep { /^$pattern\.($filetypePattern)$/ } getFileList("../".$path,$ignoreSubDirPattern);
        foreach (@allFiles){
            push(@customFiles, $_) unless basename($_) =~ /^($ignorePattern)\.($ignorePatternFiletype)/ ;
        }
        if( @customFiles ){
           @customFiles = sort map{ basename($_).",".$outputtype.",".$_ } @customFiles; 
           _writeCsv(1,\@customFiles);
        }
    }
    return 1;
}

sub evaluateSitePrefs {

    my @sitePrefRules = grep { $_->{"type"} eq 'sitepref' } @{ $control{config}->{rules} };
    my $session = Foswiki->new();
    my $object = Foswiki::Prefs->new($session);
    $object->loadSitePreferences();
    my @customPrefs = ();
    my $urlHost = quotemeta($Foswiki::cfg{DefaultUrlHost});
    my $sitePreferences = File::Spec->catfile("..","data",$Foswiki::cfg{LocalSitePreferences}=~s /\./\//r);

    foreach (@sitePrefRules){
        my $prefKey = $_->{"preference"} || "";
        if( $prefKey ){
            my $prefValue = defined $object->getPreference($prefKey) ? $object->getPreference($prefKey) : "missing SitePreference";
            my $defaultValue = $_->{"standardvalue"} || "";
            my $outputtype = $_->{"outputtype"} || "custom SitePreference";
            my $defaultType = $_->{"standardtype"} || "";

            $prefValue = Foswiki::Func::expandCommonVariables($prefValue) =~ s/$urlHost//r unless $prefValue !~ /%/;

            if( $prefValue ne $defaultValue ){
                if( $defaultType eq "path" && $prefValue ne "" ){
                    my $filename = basename( $prefValue );
                    $prefValue = File::Spec->catdir("..",$prefValue) unless $prefValue =~ /^http.*/;
                    $prefValue = $filename.",".$outputtype.",".$prefValue;
                }else{
                    $prefValue = $prefKey.",".$outputtype.",".$prefValue;
                }
                push(@customPrefs, $prefValue);
            }
        }
    }
    $object->finish();
    $session->finish();
    _writeCsv(1,\@customPrefs);
    return 1;
}


sub wildcardReplacement {
    my $string = shift;
    $$string = quotemeta($$string);
    $$string =~ s/\\\*/.*/g;
    $$string =~ s/\\\?/./g;
}


sub getFileList{
    my $dir = shift;
    my $ignoreSubDirs = shift;
    my $dirHandle;
    my @files;
    my @fileList = ();

    debug($dir);

    if( !(-d $dir) ){
        debug("$dir not found");
        return @fileList;
    }

    opendir($dirHandle, $dir);
    @files = grep { not /^(\.)+$/ } readdir($dirHandle);
    closedir($dirHandle);

    @files = map { $dir . '/' . $_ } @files;

    foreach (@files){
        if ( -d $_ ){
            # skip all sub directories which are defined in $ignoreSubDirs
            push(@fileList, getFileList($_,$ignoreSubDirs)) unless basename($_) =~ /($ignoreSubDirs)/;
        }else{
            push(@fileList, $_);
        }
    }
    return @fileList;
}


sub _getJSONConfig {

    my $jsonPath = shift;

    if(-e $jsonPath){
        my $filehandle;
        unless( open($filehandle, '<', $jsonPath) ){
            die("could not open josn file at $jsonPath");
        }else{
            local $/ = undef;
            my $jsonText = <$filehandle>;
            close($filehandle);
            my $jsonConfig = decode_json($jsonText);
            $control{config}=$jsonConfig;
        }
    }
}

sub _writeCsv {
    my $csvtarget = $control{csvfile};
    my $append = shift;
    my @content = @{$_[0]};
    my $filehandle;
    if($append){
        if (open($filehandle, '+>>', $csvtarget) ){
            print $filehandle join("\n",@content)."\n";
            close($filehandle);
        }else{
            warn("could not write to $csvtarget");
        }
    }else{
         if (open($filehandle, '+>', $csvtarget) ){
            print $filehandle join("\n",@content)."\n";
            close($filehandle);
        }else{
            warn("could not write to $csvtarget");
        }
    }
}
1;

__END__

=pod

=head1 tools/customization_identifier.pl

Compares the Q.wiki installation to a set of customization definitions. The customization 
definitions are provided as json. The script produces a csv file in the tools directory 
following the default naming convention YYMMDD_Customer_Overview_Customizing.csv.

=head1 SYNOPSIS

    perl customization_identifier.pl [options]

=head1 OPTIONS

=over

=item B<-c> config

    -c lets you specify a path to a json file for the customization rules.

    Without this option the default file tools/customization_definition.json is used.

    The config file currently uses three main rule types: file, plugin and sitepref.
    The outputtype parameter specifies the content of the type field in the created 
    csv for matching results.

=over

    file describes rules for matching files. Specific pathes to search, filestypes and 
    names can be specified. Using the ignore key sub directories, names and filetypes 
    can be excluded from matching. Path, name and type related entries can contain * 
    as wildcard.

    plugin specifies the list of non-custom/standard plugins and contribs.

    sitepref compares SitePreference key-value pairs to defined standard values. If the 
    value is a path use "standardtype": "path" to output the relative-path (in perspective 
    to the tools directory) into the csv.

=back

=item B<-o> target

    -o lets you specify the csv target file.

    Without this option the default output file tools/YYMMDD_Customer_Overview_Customization.csv is created.

=item B<-help>

    Prints this help.

=back
