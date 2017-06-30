#!/usr/bin/perl -W

use Getopt::Long qw(:config no_getopt_compat bundling);
use File::Basename qw(dirname basename);
chdir dirname($0);

use constant {
	PROGNAME => basename($0),
	PROGVER  => '0.1',
	PROGDATE => '2016-05',

	DEFAULT_COMMENT => "This file was autogenerated from the man page with 'make README.md'",
};

my ($section, $subsection, $prev_section);
my ($is_synopsis, $in_list, $start_list_item, $is_deflist, $in_rawblock);
my ($progname, $mansection, $version, $verdate);
my $headline_prefix = '# ';
my $section_prefix  = '# ';
my $subsection_prefix  = '## ';
my $re_token = '(?:"[^"]*"|[^"\s]+)(?=\s|$)';

my %paste_after_section  = ( );  # ('section' => ['filename'...], ...)
my %paste_before_section = ( );
my $add_comment;

my %words = ( );
my %stopwords = map { $_ => 1 } (qw(
	a an the
	as at and but by for from nor or so yet while if on of off to it its it's
	on in onto into with within unless while after before once since until when since
));

#require 'dumpvar.pl';

sub Syntax (;$) {
	printf STDERR <<EOT, PROGNAME;
syntax: %s [OPTIONS] < input.nroff > output.md
Options:
  -p, --paste-after SECTION:FILENAME   Pastes the contents of FILENAME
                                       after the input SECTION.
  -P, --paste-before SECTION:FILENAME  Pastes the contents of FILENAME
                                       right before the input SECTION.
  -c, --comment [COMMENT]   Adds an invisible comment as first line.
                            Uses a default comment without its argument.
  -w, --word WORD  Adds a word to the list of words
                   not to be titlecased in chapter titles.
  -h, --help     Show program help
  -V, --version  Show program version

EOT
	exit ($_[0] // 0);
}

sub Version () {
	printf <<EOT, PROGNAME, PROGVER, PROGDATE;
%s v%s
Written by Maximilian Eul <maximilian\@eul.cc>, %s.

EOT
	exit;
}

GetOptions(
	'p|paste-after=s@'	=> sub{ add_paste_file('after', split /:/, $_[1]) },
	'P|paste-before=s@'	=> sub{ add_paste_file('before', split /:/, $_[1]) },
	'c|comment:s'		=> sub{ $add_comment = (length $_[1])  ? $_[1] : DEFAULT_COMMENT },
	'w|word=s'		=> sub{ $words{ lc $_[1] } = $_[1] },
	'h|help'		=> sub{ Syntax 0 },
	'V|version'		=> sub{ Version },
);

sub add_paste_file ($$$) {
	my ($op, $section, $filename) = @_;
	die "file not readable: $filename"  unless (-f $filename && -r $filename);
	my $addto = ($op eq 'after') ? \%paste_after_section : \%paste_before_section;
	push @{ $addto->{$section} }, $filename;
}

sub {
	my $pid = open(STDOUT, '|-');
	return  if $pid > 0;
	die "cannot fork: $!"  unless defined $pid;

	local $/;
	local $_ = <STDIN>;

	# merge code blocks:
	s/\n```\n```\n/ /g;

	# URLs:
	my $re_urlprefix = '(?:https?:|s?ftp:|www)';
	s/^(.+[^)>])(?:$)\n^(?:[<\[\(]\*{0,2}(${re_urlprefix}.+?)\*{0,2}[>\]\)])([\s,;\.\?!]*)$/[$1]($2)$3/gm;

	print;
	exit;
}->();

sub nextline {
	my $keep_blanklines = $_[0] // 0;
	do { $_ = <> } while (defined($_) && !$keep_blanklines && m/^\s*$/);
	defined $_
}

sub line_empty { m/^\s*$/ }

sub strip_highlighting {
	# remove remaining highlighting:
	s/(?:^\.[BIR]{1,2} |\\f[BIR])//g;

	# paragraphs:
	if (m/^\.br/i) {
		$_ = ($in_list) ? "" : "\n";
		return
	} elsif (m/^\.(LP|P|PP)\b/) {
		$_ = "\n";  # one blank line
		$in_list = 0;
	}

	# known special characters:
	s/\\\(lq/“/g;
	s/\\\(rq/”/g;
	s/\\\(dq/"/g;

	# other special characters, except "\\":
	s/\\([\- ])/$1/g;
#	s/\\(.)/$1/g;
}

sub section_title {
	# If the current line contains a section title,
	# this function sets $section, $prev_section, and the $is_... flags accordingly
	# and returns true.
	return 0 unless m/^\.SH +(.+)$/m;

	$in_list = 0;
	$prev_section = $section // '';
	$section = $1;
	undef $subsection;

	$is_synopsis = ($section eq 'SYNTAX' || $section eq 'SYNOPSIS');
	1
}

sub subsection_title {
	return 0 unless m/^\.SS +(.+)$/m;

	$in_list = 0;
	$subsection = $1;
	1
}

sub reformat_syntax {
	# commands to be ignored:
	if (m/\.PD/) {
		$_ = '';
		return
	}

	# raw block markers:
	if (m/^\.(?:nf|co|cm)/) {
		$in_rawblock = 1;
		if (m/^\.cm(?:\s+($re_token))?/) {
			chomp;
			$_ = qtok($1);
			strip_highlighting();
			$_ = "\n**\`$_\`**\n\n"
		} elsif (m/^\.co/) {
			$_ = "\n"
		} else {
			$_ = ''
		}
		return
	}

	# command invocation in Synopsis section:
	if ($is_synopsis && !line_empty()) {
		# only code here
		chomp;
		strip_highlighting();
		$_ = "\`\`\`\n$_\n\`\`\`\n";
		return
	}

	# bold and italics:
	s/\\fB(.+?)\\fR/**$1**/g; s/^\.B +(.+)/**$1**/g;
	s/\\fI(.+?)\\fR/*$1*/g;   s/^\.I +(.+)/*$1*/g;
	s/^\.([BIR])([BIR]) *(.+)/alternating_highlighting($1, $2, $3)/ge;

	# other formatting:
	strip_highlighting();

	if ($section eq 'AUTHOR') {
		# convert e-mail address to link:
		s/\b(\w[\w\-_\.\+]*@[\w\-_\+\.]+?\.[\w\-]+)\b/[$1](mailto:$1)/u;
	}

	# lists and definition lists:
	if (m/^\.IP/ || m/^\.TP/) {
		$is_deflist = m/^\.TP/ && $section ne 'EXIT CODES';
		my $indent = ($in_list > 1)
			? '    ' x ($in_list - 1)
			: '';
		$_ = $indent . '* ';  # no trailing break here
		if (!$in_list) {
			$_ = "\n$_";
			$in_list = 1;
		}
		$start_list_item = 1;
	} elsif ($in_list && m/^\.RS/) {
		$in_list++;
		$_ = ''
	} elsif ($in_list && m/^\.RE/) {
		$in_list--;
		$_ = ''
	} elsif ($in_list) {
		if ($start_list_item) {
			$start_list_item = 0;

			# In definition list (probably some CLI options).
			# Add extra line break after option name:
			s/$/  /  if $is_deflist;
		} else {
			my $indent = ' ' x (2 + (4 * ($in_list - 1)));
			s/^/$indent/;
		}
	}
}

sub qtok ($) { ($_[0] =~ m/^"(.+)"$/) ? $1 : $_[0] }

sub print_section_title    ($) { print "\n$section_prefix$_[0]\n\n" }
sub print_subsection_title ($) { print "\n$subsection_prefix$_[0]\n\n" }

sub paste_file {
	my $filename = shift;
	return 0 unless -r $filename;

	if ($filename =~ m/^(.+)\.md$/) {
		my $section_title = $1;
		print_section_title $section_title;
	}

	open FH, "< $filename";
	local $/;
	my $content = <FH>;
	close FH;

	$content =~ s/\s+$//;
	print "$content\n";

	1
}

sub alternating_highlighting {
	my @hl = @_[0, 1];
	my @tokens = split /\s+/, $_[2];
	my $h = 0;

	return join '', map {
		my $highlightkey = $hl[$h];
		$h++, $h %= 2;

		if ($highlightkey eq 'R') {
			$_
		} elsif ($highlightkey eq 'I') {
			'*' . $_ . '*'
		} elsif ($highlightkey eq 'B') {
			'**' . $_ . '**'
		}
	} @tokens
}

sub titlecase {
	local $_ = $_[0];
	my $re_word = '(\pL[\pL\']*)';

	# lowercase stop words, keep case of known words, else titlecase
	s!$re_word!$stopwords{lc $1} ? lc($1) : ($words{lc $1} // ucfirst(lc($1)))!ge;
	# capitalize first word following colon or semicolon
	s/ ( [:;] \s+ ) $re_word /$1\u$2/x;
	# title first word (even a stopword), except if it's a known word
	s!^\s*$re_word!$words{lc $1} // ucfirst(lc($1))!e;

	$_
}

##############################

# eat first line, extract progname, version, and man section
nextline()
	and m/^\.TH $re_token ($re_token) ($re_token) ($re_token)/
	and (($mansection, $verdate) = (qtok $1, qtok $2))
	and qtok($3) =~ m/^(\w[\w\-_\.]*) v? ?(\d[\w\.\-\+]*)$/
	and (($progname, $version) = ($1, $2))
	or die "could not parse first line";

# skip NAME headline, extract description
if (nextline() && section_title() && $section eq 'NAME') {
	if (nextline() && m/ \\?- +(.+)$/) {
		$description = $1;
		nextline();
	}
}

print "[//]: # ($add_comment)\n\n"  if defined $add_comment;
print "$headline_prefix$progname($mansection)";
print " - $description"  if defined $description;
print "\n\n";

print "Version $version, $verdate\n\n" if ($version && $verdate);

# skip SYNOPSIS headline
nextline() if (section_title && $is_synopsis);


do {
	if ($in_rawblock) {
		if (m/^\.(?:fi|cx)/) {
			# code block ends
			$in_rawblock = 0;
			print "\n"  if m/^\.cx/;
		} else {
			# inside code block without formatting
			strip_highlighting;
			s/\\(.)/$1/g;  # in md raw blocks, backslashes are not special!
			print "    $_"
		}

	} elsif (section_title) {
		# new section begins
		if (defined $paste_after_section{$prev_section}) {
			paste_file($_)  foreach (@{ $paste_after_section{$prev_section} });
			undef $paste_after_section{$prev_section};
		}
		if (defined $paste_before_section{$section}) {
			paste_file($_)  foreach (@{ $paste_before_section{$section} });
			undef $paste_before_section{$section};
		}
		print_section_title titlecase($section)

	} elsif (subsection_title) {
		# new subsection begins
		print_subsection_title $subsection

	} elsif (m/^\.de\b/) {
		# macro definition -- skip completely
		1 while (nextline(1) && ! m/^\.\./);

	} else {
		reformat_syntax;
		print
	}

} while (nextline(1));


foreach (values %paste_before_section)
	{ paste_file($_)  foreach (@$_) }
foreach (values %paste_after_section)
	{ paste_file($_)  foreach (@$_) }

