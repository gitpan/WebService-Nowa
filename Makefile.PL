use inc::Module::Install;
name 'WebService-Nowa';
all_from 'lib/WebService/Nowa.pm';
requires 'Encode';
requires 'Scalar::Util';
requires 'List::Util';
requires 'Web::Scraper';
requires 'Time::HiRes';
requires 'Carp';
requires 'URI';
requires 'JSON::Syck';
requires 'WWW::Mechanize';
requires 'Crypt::SSLeay';

auto_include;
WriteAll;
