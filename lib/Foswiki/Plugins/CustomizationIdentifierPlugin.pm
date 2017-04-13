# See bottom of file for default license and copyright information
package Foswiki::Plugins::CustomizationIdentifierPlugin;

use strict;
use warnings;

use Foswiki::Func    ();    # The plugins API
use Foswiki::Plugins ();    # For the API version

our $VERSION = "1.00";
our $RELEASE = "1.00";
our $NO_PREFS_IN_TOPIC = 1;
our $SHORTDESCRIPTION = 'Migration tool for identifying customizations in a Q.wiki installation.';

sub initPlugin {
    my ( $topic, $web, $user, $installWeb ) = @_;

    # check for Plugins.pm versions
    if ( $Foswiki::Plugins::VERSION < 2.0 ) {
        Foswiki::Func::writeWarning( 'Version mismatch between ',
            __PACKAGE__, ' and Plugins.pm' );
        return 0;
    }

    # Allow a sub to be called from the REST interface
    # using the provided alias
    Foswiki::Func::registerRESTHandler( 'CUSTOMIZATIONIDENTIFIER', \&customizationIdentifier );

    # Plugin correctly initialized
    return 1;
}

sub customizationIdentifier {
    # stub for later frontend usage of tools/customization_identifier.pl
    return 1;
}

1;

__END__
Q.Wiki CustomizationIdentifierPlugin - Modell Aachen GmbH

Author: %$AUTHOR%

Copyright (C) 2016 Modell Aachen GmbH

This program is free software; you can redistribute it and/or
modify it under the terms of the GNU General Public License
as published by the Free Software Foundation; either version 2
of the License, or (at your option) any later version. For
more details read LICENSE in the root of this distribution.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

As per the GPL, removal of this notice is prohibited.
