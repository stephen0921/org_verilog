#!/usr/bin/perl -w
use Carp;
use JSON;
use Template;
use Getopt::Long;
use Cwd;
use File::Basename;
use Data::Dumper;

my $json_fn = "";
my $out_dir = "";

my $cmdok = GetOptions (
			"i=s" => \$json_fn,
			"o=s" => \$out_dir,
			"help" => \$help,
		       );

if ($json_fn eq "") {
  help_info();
}

if ($out_dir eq "") {
  $out_dir = cwd() . "/gen";
  if (-d $out_dir) {
    print "[DEBUG] ./gen is already here, please remove it\n.";
    exit 0;
  }
  print "[DEBUG] The output files will be put just in dir ./gen\n";
  mkdir "$out_dir";
} else {
  if (-d $out_dir) {
    print "[DEBUG] The output files will be put just in dir $out_dir\n";
  } else {
    print "[DEBUG] The output files will be put just in dir $out_dir\n";
    mkdir "$out_dir";
  }
}

if (!$cmdok || $help) {
  help_info();
}

my $perl_scalar = read_json($json_fn);
my $org_fn = $perl_scalar->{org_file};
my $outputs = $perl_scalar->{outputs};

my %care_outputs_h;

chdir "$out_dir";

if ((!defined $org_fn) or (! -e $org_fn)) {
  print "[DEBUG] org file must be given in $json_fn\n";
  exit;
}

if ((defined $outputs) and ($outputs ne "")) {
  print "[DEBUG] outputs:$outputs are cared by user\n";
  my @keys = split(',',$outputs);
  %care_outputs_h = map {; "$_" => 1} @keys;
}

if (!defined $prefix_name) {
  $prefix_name = "default";
}

my $org_star = '*';
my $fh;
open($fh, "$org_fn");
my @lines = <$fh>;
@lines = grep {/^(\Q$org_star\E)+\s/} @lines;
chomp(@lines);
close($fh);

my $lines_info_ref; #store hash ref for every lines
my $cnt = 0;
while ($cnt < ($#lines+1)) {
  if ($cnt == 0) {
    $cnt ++;
    next;
  }
  my $tmp = $cnt-1;
  my @tmp_lines = @lines[0..$tmp];
  get_parent_node(\@tmp_lines, $lines[$cnt], $cnt);
  $cnt ++;
}

#complete the empty elements at last
if (scalar(@{$lines_info_ref}) < $#lines+1) {
  $lines_info_ref->[$#lines] = undef;
}

#complete the title name, leaf, level
$cnt = 0;
my @arrs;
foreach my $item (@{$lines_info_ref}) {
  if (! defined $item) {
    my $name = get_title($lines[$cnt]);
    my $level = get_level($lines[$cnt]);
    $lines_info_ref->[$cnt]->{name} = $name;
    $lines_info_ref->[$cnt]->{leafs} = [];
    $lines_info_ref->[$cnt]->{level} = $level;
    $cnt ++;
  }
  else {
    my $name = get_title($lines[$cnt]);
    my $level = get_level($lines[$cnt]);
    $lines_info_ref->[$cnt]->{name} = $name;
    $lines_info_ref->{$cnt}->{level} = $level;
    if (grep {/^\Q$name\E$/} @arrs) {
      print "[ERROR] Duplicated assign, please fix: $name\n";
    }
    push(@arrs, $name);
    $cnt ++;
  }
}

my $vars; # to store reference model info

$vars = get_vars();

gen_verilog_file($vars);

sub get_vars {
  my $vars;
  my @inputs;
  my @outputs;
  my @wires; # internal wires
  my $signal_href; # store signals that has children.For example, utputs or internal wires
  my $inputs_href;
  foreach my $item (@{$lines_info_ref}) {
    if (defined $signal_href->{$item->{name}}) {
    }
    else {
      if (scalar(@{$item->{leafs}}) !=0) {
	$signal_href->{$item->{name}} = 1;
      }
    }
    if (scalar(@{$item->{leafs}}) == 0) {
      # can be input, also not
      # think about it in the following 2 corners, c can not be input
      # * a
      # ** b
      # *** c
      # ** & c
      # *** d
      # or
      # * a
      # ** c
      # * c
      # ** b
      $inputs_href->{$item->{name}} = 1;
    }
    else {
      if (scalar keys (%care_outputs_h) == 0) {
	# user do not set outputs in json file, then parse org file to get outputs
	if ($item->{level} == 1) {
	  # A output is found
	  push(@outputs, $item->{name});
	}
      }
      
      else {
	# user set outputs in json file
	if (exists $care_outputs_h{$item->{name}}) {
	  push(@outputs, $item->{name});
	  $care_outputs_h{$item->{name}} = 0;
	}
      }
    }
  }

  foreach my $item (keys %{$inputs_href}) {
    if (exists $signal_href->{$item}) {
      # not an input
      delete $inputs_href->{$item};
    }
    else {
      push(@inputs, $item);
    }
  }

  foreach my $item (keys %{$signal_href}) {
    if (grep {/^\Q$item\E$/} @outputs) {
    }
    else {
      push(@wires, $item);
    }
  }

  foreach my $item (keys %care_outputs_h) {
    if ($care_outputs_h{$item} == 1) {
      print "[DEBUG] output $item can not be found in org-file $org_fn\n";
    }
  }
  $vars->{inputs}  = [@inputs];
  $vars->{outputs} = [@outputs];
  $vars->{wires}   = [@wires];
  $vars->{lines_info_ref} = $lines_info_ref;
  $vars->{prefix_name} = $prefix_name;
  return $vars;
}

sub gen_verilog_file {
  my ($vars) = @_;
  my $tt = "ref_model.tt";
  my $tt_dir = "../tpl";
  my $out = $tt;
  $out =~s/\.tt$/\.v/;
  $out = $prefix_name . "_" . $out;
  template_proc($tt, $tt_dir, $out, $out_dir, $vars);
}

sub read_json {
  my ($file) = @_;
  my $json_text;
  my $perl_text;
  local $/;
  open(my $fh, '<', "$file") or croak "Cano not open file $file: $!";
  $json_text = <$fh>;
  # delete comments
  my @json_lines = grep {!/^\s*#.*$/} @lines;
  $json_text = join("\n", @json_lines);
  $perl_text = decode_json($json_text);
  close($fh);
  return $perl_text;
}

sub template_proc {
  my ($tt, $tt_dir, $out, $out_dir, $vars) = @_;
  if (! -d $out_dir) {
    `mkdir -p $out_dir`;
  }
  my $config = {
		INCLUDE_PATH => "$tt_dir",
		INTERPOLATE  => 0,
	       };
  my $template = Template->new($config);
  chdir($tt_dir);
  $template->process("$tt", $vars, "$out_dir/$out") || croak $template->error();
}

sub get_parent_node {
  my ($lines_ref, $line, $cnt) = @_;
  my $index = scalar(@{$lines_ref}) - 1; # begin with 0
  my $own_level = get_level($line);
  my $own_content = get_title_and_logic($line);
  foreach $item (reverse @{$lines_ref}) {
    my $item_level = get_level($item);
    if ($item_level == ($own_level -1)) {
      # find parent
      push(@{$lines_info_ref->[$index]->{leafs}}, $cnt);
      push(@{$lines_info_ref->[$index]->{contents}}, $own_content);
      last;
    }
    $index --;
  }
}

sub get_info {
  my ($group_ref, $level_arr_ref, $title_logic_arr_ref, $info_num_ref) = @_;

  if (${$info_num_ref} < scalar(@{$group_ref})) {
    my $tmp = ${$info_num_ref};
    my $level = get_level($group_ref->[$tmp]);
    my $title_logic = get_title_and_logic($group_ref->[$tmp]);
    push(@{$level_arr_ref}, $level);
    push(@{$title_logic_arr_ref}, $title_logic);
    ${$info_num_ref} ++;
    #call self
    get_info($group_ref, $level_arr_ref, $title_logic_arr_ref, $info_num_ref);
  }
  return 0;
}

sub get_level {
  my ($line) = @_;
  my $level = 0;
  my $pattern = $org_star;
  while ($line =~ /\Q$pattern\E/) {
    $level ++;
    $pattern .= $org_star;
  }
  return $level;
}

sub get_title {
  my ($line) = @_;
  my $title = '';
  if ($line =~/(\w+)/) {
    $title = $1;
    return $title;
  }
  else {
    croak "get title failed: $!";
  }
}

sub get_title_and_logic {
  my ($line) = @_;
  my $title_and_logic = '';
  if ($line =~ /(\Q$org_star\E)+\s+(.*)/) {
    $title_and_logic = $2;
    return $title_and_logic;
  }
  else {
    croak "get title_and_logic failed: $!";
  }
}

sub help_info {
print <<HELP;
Decription:
    According to user org-mode file, generate reference model in verilog, which is simple logic.

Options:
    -i json file             : input json file, which must be given, for example, user.json
    -o out_dir               : output files will be saved in out_dir
    -help                    : print this message
HELP
  exit 0;
}
