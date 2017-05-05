#! /usr/bin/env perl

# Copyright © 2017 Modell Aachen GmbH

use strict;
use warnings;
no warnings 'recursion';

use FindBin qw($Bin);
my $toolsDir = $Bin;

# required for Foswiki
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

our %control = (
    debug => 0,
    configfile => "customization_definition.json",
    config => undef,
    csvfile => undef,
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

    $control{config} = _getJSONConfig($control{configfile});
    die("Import of json file failed: no valid definition, aborting.") unless $control{config};

    # check proper user is running the script
    my $uid = (stat( $Foswiki::cfg{PubDir} ))[4];
    my $owner = getpwuid( $uid );

    if( $uid ne $< ){
        die("Run script with sudo -u $owner");
    }

    my $defaulturl = $Foswiki::cfg{DefaultUrlHost};
    my $rootdir = Cwd::realpath( File::Spec->updir );

    debug("qwiki root dir: $rootdir");
    debug("qwiki default url: $defaulturl");

    #create missing directory as running user; use sudo -u www-data if required
    my $csvTargetDir = _initTargetDirectory();
    my $prefix = Time::Piece::localtime->strftime('%y%m%d');
    my $suffix = $control{config}->{outputsuffix} || "Customer_Overview_Customizing";
    $control{csvfile} = File::Spec->catfile( $csvTargetDir, $prefix.$suffix.".csv" ) unless defined $control{csvfile};

    my @header = ( $control{config}->{columntitles} );
    _writeCsv(0, \@header );

    _evaluateSitePrefs( $defaulturl, $rootdir );
    _evaluateWebPrefs( $defaulturl, $rootdir );
    _evaluatePlugins();
    _evaluateContribs();
    _evaluateFiles( $defaulturl, $rootdir );

    print("Result accessible at $control{csvfile} or at $defaulturl/pub/System/CustomizationIdentifierPlugin/$prefix$suffix.csv\n");

    return 1;
}


sub debug{
    my $message = shift;
    print $message, "\n" if $control{debug};
    return 1;
}


# creates the Plugin directory in the System web, if it is missing and returns the absolute path
sub _initTargetDirectory {

    my $systemWebName = $Foswiki::cfg{SystemWebName} || "System";
    my $pubDir = $Foswiki::cfg{PubDir} || File::Spec->catdir( $toolsDir, "..", "pub" );
    my $pubPluginDir = File::Spec->catdir( $pubDir, $systemWebName, "CustomizationIdentifierPlugin" );

    # create missing directory
    if ( -d $pubPluginDir ){ 
        debug("csv target directory $pubPluginDir already exist.");
    }else{
        debug("Creating directory $pubPluginDir.");
        File::Path->mkpath( $pubPluginDir, { mode => 0755 } );
    }

    return $pubPluginDir;
}

# checks LocalSite.cfg for enabled plugins, compares to the list of standard plugins and checks the RELEASE string format
sub _evaluatePlugins {

    my $pluginsRef = $Foswiki::cfg{Plugins};
    my $qwikiRootDir = Cwd::realpath( File::Spec->updir );
    my $pluginsDir = File::Spec->catdir( $qwikiRootDir,'lib','Foswiki','Plugins' );
    my @enabledPlugins = grep { ( ref( $pluginsRef->{$_} ) eq 'HASH' ) && defined $pluginsRef->{$_}->{Enabled} && ( $pluginsRef->{$_}->{Enabled} eq '1') } keys %{ $pluginsRef };

    foreach( @enabledPlugins ){
        my $path = File::Spec->catfile($pluginsDir, "$_.pm");
        warn("missing pm file for $_") unless -e $path;
    }

    my @pluginConfig = grep { $_->{"type"} eq 'plugin' } @{ $control{config}->{rules} };
    my @standardPlugins = @{ $pluginConfig[0]->{"standard"} };
    my $outputtype = $pluginConfig[0]->{"outputtype"} || "";
    my @customPlugins = grep {my $temp = $_; ! grep($_ eq $temp, @standardPlugins)} @enabledPlugins;
    my %ticketPlugins = ();
    my $releaseString;

    foreach ( @enabledPlugins ){
        no strict 'refs';
        unless( ${'Foswiki::Plugins::'.$_.'::RELEASE'} || $_ eq 'JEditableContribPlugin' ){
            eval "use $_ ()"; warn $@ unless $@ =~ /Subroutine .* redefined at/;
        }
        $releaseString = ${'Foswiki::Plugins::'.$_.'::RELEASE'} || "";
        if( $releaseString =~ /^\d\d?\s[a-zA-Z]{3}\s\d{4}$/ ) {
            $ticketPlugins{$_} = $releaseString;
        }
    }

    @customPlugins = grep { my $temp = $_; ! grep{ $_ eq $temp } keys %ticketPlugins } @customPlugins;
    @customPlugins = sort map{ $_.","."Plugin (Community)".",".$pluginsDir."/$_.pm" } @customPlugins;
    my @ticketPluginsOutput = sort map{ $_.","."Plugin (Ticketbranch: ".$ticketPlugins{$_}."),".$pluginsDir."/$_.pm" } keys %ticketPlugins;
    _writeCsv(1,\@customPlugins);
    _writeCsv(1,\@ticketPluginsOutput);
    return 1;
}


# checks lib/Foswiki/Contrib/ directory for installed Contribs
# Non-standard Contribs are listed as well as Contribs on a ticket branch (RELEASE is a date)
sub _evaluateContribs {

    my $qwikiRootDir = Cwd::realpath( File::Spec->updir );
    my $contribDir = File::Spec->catdir( $qwikiRootDir,'lib','Foswiki','Contrib' );

    debug($qwikiRootDir);
    debug($contribDir);

    opendir(my $directoryHandle, $contribDir) or die "Cannot open directory: $!";
    my @contribs = grep { /(Contrib|Skin).pm$/ } readdir($directoryHandle);
    closedir($directoryHandle);

    my @contribConfig = grep { $_->{"type"} eq 'contrib' } @{ $control{config}->{rules} };
    my $outputtype = $contribConfig[0]->{"outputtype"} || "";

    use Data::Dumper;

    my @standardContribs = @{ $contribConfig[0]->{"standard"} };
    @contribs = sort map { substr($_, 0, -3) } @contribs;

    my @customContribs = grep {my $temp = $_; ! grep($_ eq $temp, @standardContribs)} @contribs;
    my %ticketContribs = ();
    my $releaseString;

    for my $pm (@contribs) {
        my $releaseString;
        no strict 'refs';
        unless ( ${'Foswiki::Contrib::' . $pm . '::RELEASE'} || ${'Foswiki::Plugins::' . $pm . '::RELEASE'} ) {
            require(File::Spec->catfile($contribDir, $pm.".pm" )); 
        }

        if( defined ${'Foswiki::Contrib::' . $pm . '::RELEASE'} ){
            $releaseString = ${'Foswiki::Contrib::' . $pm . '::RELEASE'} || ${'Foswiki::Plugins::' . $pm . '::RELEASE'};
            if ( $releaseString =~ /^\d\d?\s[a-zA-Z]{3}\s\d{4}$/ ) {
                $ticketContribs{$pm} = $releaseString;
            }
        }else{
            # release string might be defined in related plugin
            if( ${'Foswiki::Plugins::' . $pm . '::RELEASE'} ){
                $releaseString = ${'Foswiki::Plugins::' . $pm . '::RELEASE'};
                if ( $releaseString =~ /^\d\d?\s[a-zA-Z]{3}\s\d{4}$/ ) {
                    $ticketContribs{$pm} = $releaseString;
                }
            }else{
                debug($pm.": no release string!");
            }
        }

    }

    @customContribs = grep { my $temp = $_; ! grep{ $_ eq $temp } keys %ticketContribs } @customContribs;
    @customContribs = sort map{ $_.","."Contrib (Community)".",".$contribDir."/$_.pm" } @customContribs;
    my @ticketContribsOutput = sort map{ $_.","."Contrib (Ticketbranch: ".$ticketContribs{$_}."),".$contribDir."/$_.pm" } keys %ticketContribs;

    _writeCsv(1,\@customContribs);
    _writeCsv(1,\@ticketContribsOutput);
    return 1;

}


# checks for existing files based on rules specified in the json config
sub _evaluateFiles {

    my @fileRules = grep { $_->{"type"} eq 'file' } @{ $control{config}->{rules} };
    my $dirHandle;
    my @allFiles;
    my $defaultUrlHost = shift;
    my $rootDir = shift;
    my $qmPubDir = quotemeta( $Foswiki::cfg{PubDir} ); 
    my $qmDataDir = quotemeta( $Foswiki::cfg{DataDir} );

    foreach my $rule (@fileRules) {
        my @customFiles;
        my $path = $rule->{"path"};
        my $pattern = $rule->{"name"} || "*" ;
        my $outputtype = $rule->{"outputtype"} || "custom file";
        $pattern = _wildcardReplacement($pattern);
        my $filetypePattern = _escapedJoin("|", $rule->{"filetype"}, ".*" ); # filenames to match
        $filetypePattern =~ s/\.$//g; # remove dot before extension
        my $ignorePattern = _escapedJoin( "|", $rule->{"ignore"}->{"name"}, "" ); # filenames to ignore
        my $ignorePatternFiletype = _escapedJoin( "|", $rule->{"ignore"}->{"filetype"}, "" );
        my $ignoreSubDirPattern =_escapedJoin( "|", $rule->{"ignore"}->{"subpath"}, "" ); # sub directories to skip

        if( $pattern !~ /^.*\.[.*]$/ ){
            $pattern .= "/."; #avoid unwanted \.\. before extension
        }
        debug("complete pattern: ".$pattern."($filetypePattern) for ../$path ignoring $ignoreSubDirPattern");
        @allFiles = grep { /^$pattern($filetypePattern)$/ } _getFileList( File::Spec->catdir("..", $path) ,$ignoreSubDirPattern);
        foreach my $file (@allFiles){
            push(@customFiles, $file) unless basename($file) =~ /^($ignorePattern)\.($ignorePatternFiletype)/ ;
        }
        if( @customFiles ){
            foreach my $customFile (@customFiles){
                (my $path = $customFile) =~ s/\.\./$rootDir/g;
                (my $url = $customFile) =~ s/\.\./$defaultUrlHost/g;
                if( $path  =~ /^($qmPubDir|$qmDataDir).*/g ){
                    $customFile = basename($customFile).",".$outputtype.",".$path.",".$url;
                }else{
                    $customFile = basename($customFile).",".$outputtype.",".$path.",only accessible via SSH";
                }
            }
            @customFiles = sort @customFiles;
           _writeCsv(1,\@customFiles);
        }
    }
    return 1;
}


# checks SitePreference entries against expected default values
sub _evaluateSitePrefs {
    my $defaultUrlHost = shift;
    my $rootDir = shift;
    my $returnVal = 1;
    my @sitePrefRules = grep { $_->{"type"} eq 'sitepref' } @{ $control{config}->{rules} };
    my $session = Foswiki->new();
    my $object = Foswiki::Prefs->new($session);
    $object->loadSitePreferences();
    my @customPrefs = ();
    my $sitePreferences = File::Spec->catfile("..","data",$Foswiki::cfg{LocalSitePreferences}=~s /\./\//r);

    foreach my $rule (@sitePrefRules){
        my $prefKey = $rule->{"preference"} || "";
        if( $prefKey ){
            my $prefValue =  _getExpandedPreference(0, $prefKey, $defaultUrlHost, $object);
            my $defaultValue = $rule->{"standardvalue"} || "";
            my $outputtype = $rule->{"outputtype"} || "custom SitePreference";
            my $defaultType = $rule->{"standardtype"} || "";

            if( $prefValue ne $defaultValue ){
                if( $defaultType eq "path" && $prefValue ne "" && $prefValue !~ /^http.*/ ){
                    my $path = File::Spec->catdir( $rootDir, $prefValue );
                    my $url = $defaultUrlHost.$prefValue;
                    $prefValue = $path.",".$url;
                }
                $prefValue = $prefKey.",".$outputtype.",".$prefValue;

                push(@customPrefs, $prefValue);
            }
        }
    }
    $object->finish();
    $session->finish();
    $returnVal = _writeCsv(1,\@customPrefs);
    return $returnVal;
}


# checks WebPreference entries against expected default values or list specified WebPreferences
sub _evaluateWebPrefs {
    my $defaultUrlHost = shift;
    my $rootDir = shift;
    my $returnVal = 1;
    my @webPrefRules = grep { $_->{"type"} eq 'webpref' } @{ $control{config}->{rules} };
    my $session = Foswiki->new();
    my @customPrefs = ();

    foreach my $rule (@webPrefRules){

        my @webs = defined $rule->{"webs"} ? @{ $rule->{"webs"} } : Foswiki::Func::getListOfWebs( "user" );
        my $ignoreWebs = _escapedJoin("|", $rule->{"ignore"}->{"name"}, "");

        my $output;

        if( $rule->{"action"} eq "list" ){
            my @preferences = defined $rule->{"preferences"} ? @{ $rule->{"preferences"} } : ();
            my $outputtype = $rule->{"outputtype"} || "WebPreference listing: ";

            foreach my $web (@webs){
                # skip ignored webs
                if( ! ($ignoreWebs && $web =~ /^($ignoreWebs)/ ) ){
                    foreach my $prefKey (@preferences){
                        my $prefValue = _getExpandedPreference(1, $prefKey, $defaultUrlHost, $web);
                        $output = $prefKey.",".$outputtype.$web.",".$prefValue;
                        push(@customPrefs, $output);
                    }
                }
            }
        }else{

            my $prefKey = $rule->{"preference"} || "";
            my $defaultValue = $rule->{"standardvalue"} || "";
            my $outputtype = $rule->{"outputtype"} || "Custom WebPreference: ";

            foreach my $web (@webs){
                if( !($ignoreWebs && $web =~ /^($ignoreWebs)/ ) && $prefKey ){
                    my $prefValue = _getExpandedPreference(1, $prefKey, $defaultUrlHost, $web);
                    # compare pref value against expected value
                    if( $prefValue ne $defaultValue ){
                        $output = $prefKey.",".$outputtype.$web.",".$prefValue;
                        push(@customPrefs, $output);
                    }
                }
            }
        }
    }

    $session->finish();
    $returnVal = _writeCsv(1,\@customPrefs);
    return $returnVal;
}

# for WebPreference (1, PrefenreceKey, defaultUrlHost, Web)
# for SitePreference (0, PreferenceKey, defaultUrlHost, Pref object)
sub _getExpandedPreference{

    my $isWeb = shift;
    my $prefKey = shift;
    my $urlHost = shift;
    my $web = "";
    my $object = "";
    if( $isWeb ){
        $web = shift;
    }else{
        $object = shift;
    }

    my $prefValue = $isWeb ? Foswiki::Func::getPreferencesValue( $prefKey, $web ) : $object->getPreference($prefKey);
    $prefValue = defined $prefValue ? $prefValue : "Missing Preference";

    # expand macros 
    if( $prefValue =~ /%/ ){
        $prefValue = Foswiki::Func::expandCommonVariables($prefValue) =~ s/$urlHost//r;
    }
    return $prefValue;
}


# applies _wildcardReplacement on each value in passed array and returns a joined String
# returns ".*" if passed array is empty and no other default value was passed
sub _escapedJoin{
    my $separator = shift;
    my $arrayRef = shift;
    my $default = shift;
    $default = defined $default && $default eq "" ? $default : ".*";
    my @escapedArray = map { _wildcardReplacement( $_ ) } @$arrayRef;
    my $joinedArray = join( $separator, @escapedArray ) || $default;
    return $joinedArray;
}

# replaces * with .* and ? with .
sub _wildcardReplacement {
    my $string = shift;
    $string = quotemeta($string);
    $string =~ s/\\\*/.*/g;
    $string =~ s/\\\?/./g;
    return $string;
}

# retrieves a list of files in the passed directory and all subdirectories
sub _getFileList{
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
    @files = grep { $_ ne '.' && $_ ne '..'  } readdir($dirHandle);
    closedir($dirHandle);

    @files = map { $dir . '/' . $_ } @files;

    foreach my $file (@files){
        if ( -d $file ){
            # skip all sub directories which are defined in $ignoreSubDirs
            push(@fileList, _getFileList($file,$ignoreSubDirs)) unless basename($file) =~ /($ignoreSubDirs)/;
        }else{
            push(@fileList, $file);
        }
    }
    return @fileList;
}

# reads the json config file and returns the corresponding hash
sub _getJSONConfig {

    my $returnVal = 0;
    my $jsonPath = shift;

    if(-e $jsonPath){
        my $filehandle;
        if( open($filehandle, '<', $jsonPath) ){
            local $/ = undef;
            my $jsonText = <$filehandle>;
            close($filehandle);
            $returnVal = decode_json($jsonText);
            #$control{config}=$jsonConfig;
            #$returnVal = 1;
        }else{
            die("could not open json file at $jsonPath");
        }
    }
    return $returnVal;
}

# writes content to a csv file
# requires sudo -u www-data
sub _writeCsv {
    my ($append, $contentRef) = @_;
    my $returnVal = 1;
    my $csvtarget = $control{csvfile};
    #my $append = shift;
    my @content = @{$contentRef};
    return unless @content;
    my $filehandle;
    my $mode = '+>';
    if($append){
        $mode = '+>>';
    }
    if ( open($filehandle, $mode, $csvtarget) ){
        print $filehandle join("\n", @content)."\n";
        close($filehandle);
    }else{
        $returnVal = 0;
        warn("could not write to $csvtarget");
    }
    return $returnVal; 
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

=item B<-debug>

    Prints more information while processing the ruleset.

=back
