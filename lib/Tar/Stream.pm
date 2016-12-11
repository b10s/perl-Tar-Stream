package Tar::Stream;

#FIXME add some documentation, pod
# for given\when
use v5.10.1;
use feature qw(switch);
use strict;
use warnings;
no warnings "experimental::smartmatch";
use bytes;

#TODO change names
my @props = qw(mode uid gid mtime);
use constant BLOCK_SIZE => 512;

sub new {
	my $class = shift;
	my $args = scalar @_ % 2 == 0 ? +{ @_ } : shift;
	my $self = {};
	bless $self, $class;
	$self->_check_args( $args, qw(name) ) or return;
	$self->{inode} = {};
	$self->{name} = $args->{name};

	#TODO maybe have to lock file for other IO
	#TODO allow to set file handle from outside: it can be socket as well
	open( $self->{tar_fh}, '>', $self->{name} );
	return $self;
}

sub add_member {
	my $self = shift;
	my $args = scalar @_ % 2 == 0 ? +{ @_ } : shift;

	#TODO make file size computable

	$self->_pad_inode();

	$self->_check_args( $args, qw(name size type mode uid gid mtime) ) or return;
	map { $self->{inode}{$_} = $args->{$_} } keys %$args;

	#FIXME make good error handling
	warn 'wrong name' if length $args->{name} == 0;
	#TODO add default properties, maybe change line below
	# use tar properties as defaults for member @props: mode, uid, gid, mtime..
	map { $self->{inode}{$_} //= $self->{$_} if exists $self->{$_} } @props;
	#my @props = qw(mode uid gid mtime);
	# SUID|SGID : owner : group : other
	#FIXME test all modes
	#FIXME find out what for all that bytes
	#FIXME make that properties mandatory
	$self->{inode}{mode}  //= '0000664';
	$self->{inode}{uid}   //= '1000';
	$self->{inode}{gid}   //= '1000';
	$self->{inode}{mtime} //= time();

	# translate type to tar format
	#TODO make type more comfortable and check it as mandatory
	# 5 and 0 is string
	$self->{inode}{type} = $self->{inode}{type} eq 'dir' ? '5' : '0';

	# check file length for @LongLink
	my $name_len = length $self->{inode}{name};
	# @LongLink format of member name
	$self->_add_longlink_header($name_len)  if $name_len > 100;
	# add common header
	$self->_add_header();

	#TODO add check for disk space bore tar file if member size is known
	# remember data len of member
	$self->{inode}{len} = 0;
}

sub DESTROY {
	my $self = shift;
	$self->finish() if exists $self->{tar_fh};
	#FIXME close file and check if all is ok
}

sub add_data {
	my ( $self, $data ) = @_;
	#FIXME add check for data

	#TODO calculate it by overflow of 1000000000 or keep at for header
	$self->{inode}{len} += length $data;
	print { $self->{tar_fh} } $data;
}

#TODO may be another name: end or close
sub finish {
	my $self = shift;
	$self->_pad_inode();

	# add two zeroes blocks as end archive marker
	print { $self->{tar_fh} } "\0" x ( BLOCK_SIZE * 2);
	close( $self->{tar_fh} );
	delete $self->{tar_fh};
}

sub _check_args {
	my ( $self, $args, @check ) = @_;
	my $errors = {};
	#TODO optimize that; maybe dont change args;
	my $fargs = {};
	for my $arg ( @check ) {
		$fargs->{$arg} = $args->{$arg};
		given($arg){
			#TODO make proper checks for arguments
			when(['name','size','type','mode','uid','gid','mtime']){
				$errors->{$_} = 'required' if not exists $args->{$_} or not defined $args->{$_};
			}
		}
	}
	foreach( keys $errors ) {
		warn "[ERR] key `$_': `$errors->{$_}'";
	}
	return 0 if keys $errors;
	$args = $fargs;
	return 1;
}

# add null-bytes to align data by BLOCK_SIZE bytes; inner use only
sub _pad_inode {
	my $self = shift;
	my $file_padding = 0;
	if( exists $self->{inode}{len} ) {
		$file_padding = BLOCK_SIZE - ( $self->{inode}{len} % BLOCK_SIZE );
	}
	print { $self->{tar_fh} } "\0" x $file_padding if $file_padding;
}

sub _add_longlink_header {
	#FIXME test LongLink for empty files, folders, not empty
	#with zeros in first header
	my ( $self, $name_len ) = @_;
	my $header = '';
	$header .= pack( 'Z100', '././@LongLink' ); # marker of @LongLink
	#FIXME calculate it somehow; what diff with second one?
	#TODO try without mode
	$header .= pack( 'A7x', $self->{inode}{mode} ); # member mode, null-padded, 7 nums
	$header .= pack( 'A7x', '0'x7 ); # uid with zeros, null-padded, 7 nums
	$header .= pack( 'A7x', '0'x7 ); # gid with zeros, null-padded, 7 nums
	$header .= pack( 'A12', sprintf('%.12o', $name_len) ); # size, only 12 nums, null-padded
	$header .= pack( 'A11x', '0'x11 ); # mtime, null padded, octal
	$header .= pack( 'A8', ); # checksum; before calculate its just 8 spaces
	$header .= pack( 'A', 'L' ); # link indicator(file type)
	$header .= pack( 'Z100', ); # link name; not supported

	my $checksum = 0;
	$checksum = unpack( '%18C*', $header ); # sum of all bytes in header
	# paste checksum in place as 6 octal nums
	substr( $header, 148, 8, pack( "A8", sprintf("%.6o\0 ", $checksum) ) );
	$header .= "\0" x ( BLOCK_SIZE - length $header ); # align header
	print { $self->{tar_fh} } $header;

	#TODO use sub instead print
	print { $self->{tar_fh} } $self->{inode}{name};
	# align long member name to BLOCK_SIZE
	print { $self->{tar_fh} } "\0" x ( BLOCK_SIZE - ($name_len % BLOCK_SIZE) );
}

sub _add_header {
	my $self = shift;

	my $header = '';
	#FIXME allow to use long names
	$header .= pack( 'Z100', $self->{inode}{name} );
	#FIXME validate file mode
	#TODO be sure that in LongLink proper mode
	$header .= pack( 'A7x', sprintf('%.7d', $self->{inode}{mode} ) );
	#FIXME validate uid
	$header .= pack( 'A7x', sprintf('%.7d', $self->{inode}{uid})); #uid
	$header .= pack( 'A7x', sprintf('%.7d', $self->{inode}{gid})); #gid
	#TODO check 12 nums for size
	$header .= pack( 'A12', sprintf('%.12o', $self->{inode}{size})); #size
	#mtime #TODO null or tab padded or recedeed by zeroes?
	$header .= pack( 'A11x', sprintf('%.11o', $self->{inode}{mtime}));
	$header .= pack( 'A8', ); #checksum
	#TODO may be add links somehow ? but have no idea how
	$header .= pack( 'A', $self->{inode}{type} ); # 0 -for file; 5 -for dir;
	$header .= pack( 'Z100', ); #link name
	my $checksum = 0;
	$checksum = unpack( '%18C*', $header ); # sum of all bytes in header
	# paste checksum in place as 6 octal nums
	substr( $header, 148, 8, pack("A8", sprintf("%.6o\0 ", $checksum)) );
	$header .= "\0" x ( BLOCK_SIZE - length $header );

	#FIXME change to syswrite or some without buffering
	#TODO should i use bufer or not?
	print { $self->{tar_fh} } $header;
}

1;
