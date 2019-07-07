requires 'perl', '5.012';

# requires 'Some::Module', 'VERSION';
requires 'Carp';

requires 'File::Basename';
requires 'File::Copy';
requires 'File::Spec';
requires 'IO::File';
requires 'XML::LibXML';
requires 'Encode';
requires 'Digest::SHA1';
requires 'URI';
requires 'Archive::Zip';
requires 'Scalar::Util';
requires 'version';
requires 'File::Temp';
requires 'Data::Dumper';
requires 'boolean', '0.32';
requires 'DateTime::Format::ISO8601';
requires 'Log::Log4perl';
requires 'XML::SAX';
requires 'XML::SAX::Base';
requires 'LWP::UserAgent';
requires 'LWP::Protocol::https';

# This syntax is not working
#requires 'TabParser','0.01', git => 'git://github.com/inab/TabParser.git', ref => '0.01';
requires 'TabParser', '0.01', url => 'https://github.com/inab/TabParser/archive/0.01.tar.gz';

on test => sub {
    requires 'Test::More', '0.96';
};

on develop => sub {
    requires 'Dist::Milla', '1.0.20';
};