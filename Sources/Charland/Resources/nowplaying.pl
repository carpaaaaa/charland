# Carica il lettore di «In riproduzione» di Charland dentro perl e lo fa girare.
use strict;
use DynaLoader;
my $lib = DynaLoader::dl_load_file($ARGV[0], 0) or die "load: " . DynaLoader::dl_error() . "\n";
my $sym = DynaLoader::dl_find_symbol($lib, "charland_nowplaying_run") or die "symbol\n";
DynaLoader::dl_install_xsub("main::run", $sym);
run();
