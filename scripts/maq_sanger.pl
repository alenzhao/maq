#!/usr/bin/perl -w

# Author: lh3

use strict;
use warnings;
use Cwd qw/getcwd/;
use Getopt::Std;
use File::Spec;

my $version = '0.1.16';
my %opts = (l=>36, 1=>0, 2=>0, 3=>0, 4=>0, a=>250, n=>2000000, d=>'', A=>0,
			R=>'select[mem>800 && type==X86_64] rusage[mem=800]');
getopts('l:1:2:a:n:sR:zd:S3:4:f:A:e:', \%opts);
die(qq(
Program: maq_sanger.pl (run maq jobs on Sanger Inst's computing farm)
Contact: lh3
Version: $version
Usage:   maq_sanger.pl [options] <run.dir> <ref.bfa> <read1.fastq> [<read2.fastq> [...]]

Options: -l INT       length of the read1 [$opts{l}]
         -n INT       number of reads in a .bfq file [$opts{n}]
         -1 INT       skip the first few bases of read1 [$opts{1}]
         -2 INT       skip the first few bases of read2 [$opts{2}]
         -3 INT       length of read1 [$opts{3}]
         -4 INT       length of read2 [$opts{4}]
         -a INT       maximum insert size [$opts{a}]
         -A INT       maximum insert size of RF pairs, 0 for short [$opts{A}]
         -R STR       resources [$opts{R}]
         -d FILE      3'-adapter file [null]
         -f FILE      flag file to delete in the end [null]
         -S           qualities are scaled in the Solexa way
         -s           single end (suppress -l, -1, -2 and -4)
         -z           the input is compressed

Example: maq_sanger.pl -l 35 255 /lustre/scratch1/lh3/data/human_b36_female.bfa /nfs/repository/d0033/SLX_1000_A2_TRIO_NA12_WG/255_s*.fastq | sh
\n)) if (@ARGV < 3);
$opts{n} >>= 1 unless (defined $opts{s});
$opts{R} = $opts{R}? qq/-R'$opts{R}'/ : '';
my $maq = gwhich('maq') || die("[maq_sanger] fail to find 'maq'");
my $maq_pl = gwhich('maq.pl') || die("[maq_sanger] fail to find 'maq.pl'");
my $asub = gwhich('asub') || die("[maq_sanger] fail to find 'asub'");
my $outdir = shift(@ARGV);
my $ref = File::Spec->rel2abs(shift(@ARGV));
die("[maq_sanger] fail to stat reference file '$ref'\n") unless (-e $ref);
my $files = '';
for my $f (@ARGV) {
  die("[maq_sanger] read files must be ended with '.fastq' or '.fq'\n")
	unless ($f =~ /\.fastq$/ || $f =~ /\.fastq\.gz$/ || $f =~ /\.fq$/ || $f =~ /\.fq\.gz$/);
  die("[maq_sanger] fail to stat read file '$f'\n") unless (-e $f);
  $files .= " " . File::Spec->rel2abs($f);
}
my $is_paired = !defined($opts{s})? 1 : 0;
$_ = $outdir;
s/.*\///;
my $jn = "$_.$$";

# compose the command lines

my $cwd = getcwd;
my $sol2sanger = (defined $opts{S})? "| $maq sol2sanger - -" : '';
my $cmd_generic = qq(bsub -w "done($jn.map)" -J"$jn.merge" -q long $opts{R} -o /dev/null -e aln-rmdup.log 'find map -name "*.map" | xargs $maq mapmerge - | tee aln.map | $maq rmdup aln-rmdup.map -';
  $asub -w "done($jn.merge)" -j "$jn.post" $opts{R} <<EOF
    $maq_pl statmap $jn.map.err/* > aln.stat; $maq mapstat aln-rmdup.map > aln-rmdup.mapstat
    $maq mapcheck $ref aln-rmdup.map > aln-rmdup.mapcheck
    cat unmap/*.txt | gzip > unmap.txt.gz
EOF
  bsub -w "done($jn.post)" 'rm -f aln-rmdup.mapcheck.touch aln.map.touch';
);
my $adap3 = $opts{d}? "-d ".File::Spec->rel2abs($opts{d}) : '';
if ($is_paired) { # paired end
  my $cat2pair;
  if (defined $opts{z}) {
	$cat2pair = qq(ls $files | sed 's/\.gz\$//' | xargs -i echo 'gzip -dc {}.gz | $maq catfilter - $sol2sanger | $maq_pl cat2pair -1 $opts{1} -2 $opts{2} $opts{l} - {}' | $asub -j "$jn.cat" $opts{R};);
  } else {
	$cat2pair = qq/ls $files | xargs -i echo '$maq catfilter {} $sol2sanger | $maq_pl cat2pair -1 $opts{1} -2 $opts{2} $opts{l} - {}' | $asub -j "$jn.cat" $opts{R};/;
  }
  print qq(mkdir -p $outdir/map $outdir/unmap;
cd $outdir;
$cat2pair
cat >run_script.sh <<EOT
  find read1 -name "*.bfq" | sed "s/\.bfq\$//" | sed "s/^read1//" | xargs -i echo $maq map -A $opts{A} -a $opts{a} -1 $opts{3} -2 $opts{4} $adap3 -u unmap{}.txt map{}.map $ref read1{}.bfq read2{}.bfq | $asub -j "$jn.map" -q long $opts{R};
  $cmd_generic
EOT
bsub -w "done($jn.cat)" -o /dev/null -e /dev/null <<EOF
  find . -name "*.fastq" | sed "s/\.fastq\$//" | xargs -i echo '$maq fastq2bfq -n $opts{n} {}.fastq {}' | $asub -j "$jn.bfq" $opts{R};
  cat run_script.sh | bsub -w "done($jn.bfq)" $opts{R} -o /dev/null -e /dev/null
EOF
cd $cwd;
);
} else {
  my $catfilter = '';
  if (defined $opts{z}) {
	$catfilter = qq(
ls *.fastq.gz | sed "s/\.gz\$//" | xargs -i echo 'gzip -dc {}.gz | $maq catfilter -s - $sol2sanger > {}' | $asub -j "$jn.cat" $opts{R};\n);
  } else {
	$catfilter = qq(
ls *.fastq | xargs -i mv {} {}.tmp;
ls *.tmp | sed "s/\.tmp\$//" | xargs -i echo '$maq catfilter -s {}.tmp $sol2sanger > {}' | $asub -j "$jn.cat" $opts{R};\n);
  }
  print qq(mkdir -p $outdir/read1;
cd $outdir/read1;
ls $files | xargs -i ln -s {};
find . -name "*.fq.gz" | sed "s/\.gz$//" | xargs -i ln -s {} {}.fastq.gz
find . -name "*.fq" | xargs -i ln -s {} {}.fastq
$catfilter
cd ..; mkdir -p map unmap;
cat >run_script.sh <<EOT
  find read1 -name "*.bfq" | sed "s/\.bfq\$//" | sed "s/^read1//" | xargs -i echo $maq map -1 $opts{3} $adap3 -u unmap{}.txt map{}.map $ref read1{}.bfq | $asub -j "$jn.map" -q long $opts{R};
  $cmd_generic
EOT
bsub -w "done($jn.cat)" -o /dev/null -e /dev/null <<EOF
  find . -name "*.fastq" | sed "s/\.fastq\$//" | xargs -i echo '$maq fastq2bfq -n $opts{n} {}.fastq {}' | $asub -j "$jn.bfq" $opts{R};
  cat run_script.sh | bsub -w "done($jn.bfq)" -o /dev/null -e /dev/null $opts{R}
EOF
cd $cwd;
);
}

exit;

sub dirname
{
	my $prog = shift;
	my $cwd = getcwd;
	return $cwd if ($prog !~ /\//);
	$prog =~ s/\/[^\s\/]+$//g;
	return $prog;
}
sub which
{
	my $file = shift;
	my $path = (@_)? shift : $ENV{PATH};
	return if (!defined($path));
	foreach my $x (split(":", $path)) {
		$x =~ s/\/$//;
		return "$x/$file" if (-x "$x/$file" && -f "$x/$file");
	}
	return;
}
sub gwhich
{
	my $progname = shift;
	my $addtional_path = shift if (@_);
	my $dirname = &dirname($0);
	my $tmp;

	chomp($dirname);
	if (-x $progname && -f $progname) {
		return File::Spec->rel2abs($progname);
	} elsif (defined($addtional_path) && ($tmp = &which($progname, $addtional_path))) {
		return $tmp; # lh3: Does it work? I will come back to this later
	} elsif (defined($dirname) && (-x "$dirname/$progname" && -f "$dirname/$progname")) {
		return File::Spec->rel2abs("$dirname/$progname");
	} elsif (($tmp = &which($progname))) { # on the $PATH
		return $tmp;
	} else {
		warn("[gwhich] fail to find executable $progname anywhere.");
		return;
	}
}
