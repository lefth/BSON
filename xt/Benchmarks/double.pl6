#!/usr/bin/env perl6

use v6;
use BSON;
use NativeCall;
use Bench;

my Num $n1 = 1234.6789e0;
my Buf $bn1 = encode-double($n1);
my Buf $bn2;
my Num $n2;

my $b = Bench.new;
$b.timethese(
  3000, {
    'double native encode' => sub { $bn2 = encode-double($n1); },
    'double native decode' => sub { $n2 = decode-double( $bn1, 0); },
#    'double emulated encode' => sub { $bn2 = encode-double-emulated($n1); },
#    'double emulated decode' => sub { $n2 = decode-double-emulated( $bn1, 0); },
  }
);

say "N: $n2, ", $bn2.perl;


#------------------------------------------------------------------------------
# original code
sub encode-double-emulated ( Num:D $r is copy --> Buf ) is export {

  # Make array starting with bson code 0x01 and the key name
  my Buf $a = Buf.new(); # Buf.new(0x01) ~ encode-e-name($key-name);
  my Num $r2;

  # Test special cases
  #
  # 0x 0000 0000 0000 0000 = 0
  # 0x 8000 0000 0000 0000 = -0       Not recognizable
  # 0x 7ff0 0000 0000 0000 = Inf
  # 0x fff0 0000 0000 0000 = -Inf
  # 0x 7ff0 0000 0000 0001 <= nan <= 0x 7ff7 ffff ffff ffff signalling NaN
  # 0x fff0 0000 0000 0001 <= nan <= 0x fff7 ffff ffff ffff
  # 0x 7ff8 0000 0000 0000 <= nan <= 0x 7fff ffff ffff ffff quiet NaN
  # 0x fff8 0000 0000 0000 <= nan <= 0x ffff ffff ffff ffff
  #
  given $r {
    when 0.0 {
      $a ~= Buf.new(0 xx 8);
    }

    when -Inf {
      $a ~= Buf.new( 0 xx 6, 0xF0, 0xFF);
    }

    when Inf {
      $a ~= Buf.new( 0 xx 6, 0xF0, 0x7F);
    }

    when NaN {
      # choose only one number out of the quiet NaN range
      $a ~= Buf.new( 0 xx 6, 0xF8, 0x7F);
    }

    default {
      my Int $sign = $r.sign == -1 ?? -1 !! 1;
      $r *= $sign;

      # get proper precision from base(2). Adjust the exponent bias for
      # this.
      my Int $exp-shift = 0;
      my Int $exponent = 1023;
      my Str $bit-string = $r.base(2);

      $bit-string ~= '.' unless $bit-string ~~ m/\./;

      # smaller than one
      if $bit-string ~~ m/^0\./ {

        # Normalize, Check if a '1' is found. Possible situation is
        # a series of zeros because r.base(2) won't give that much
        # information.
        #
        my $first-one;
        while !($first-one = $bit-string.index('1')) {
          $exponent -= 52;
          $r *= 2 ** 52;
          $bit-string = $r.base(2);
        }

        $first-one--;
        $exponent -= $first-one;

        $r *= 2 ** $first-one;                # 1.***
        $r2 = $r * 2 ** 52;                   # Get max precision
        $bit-string = $r2.base(2);            # Get bits
        $bit-string ~~ s/\.//;                # Remove dot
        $bit-string ~~ s/^1//;                # Remove first 1
      }

      # Bigger than one
      #
      else {
        # Normalize
        #
        my Int $dot-loc = $bit-string.index('.');
        $exponent += ($dot-loc - 1);

        # If dot is in the string, not at the end, the precision might
        # be not sufficient. Enlarge one time more
        #
        my Int $str-len = $bit-string.chars;
        if $dot-loc < $str-len - 1 or $str-len < 52 {
          $r2 = $r * 2 ** 52;                 # Get max precision
          $bit-string = $r2.base(2);          # Get bits
        }

        $bit-string ~~ s/\.//;              # Remove dot
        $bit-string ~~ s/^1//;              # Remove first 1
      }

      # Prepare the number. First set the sign bit.
      #
      my Int $i = $sign == -1 ?? 0x8000_0000_0000_0000 !! 0;

      # Now fit the exponent on its place
      #
      $i +|= $exponent +< 52;

      # And the precision
      #
      $i +|= :2($bit-string.substr( 0, 52));

      $a ~= encode-int64($i);
    }
  }

  return $a;
}

#------------------------------------------------------------------------------
# original code
# We have to do some simulation using the information on
# http://en.wikipedia.org/wiki/Double-precision_floating-point_format#Endianness
# until better times come.
#
sub decode-double-emulated ( Buf:D $b, Int:D $index --> Num ) is export {

#say "Dbl 0: ", $b.subbuf( $index, 8);

  # Test special cases
  #
  # 0x 0000 0000 0000 0000 = 0
  # 0x 8000 0000 0000 0000 = -0
  # 0x 7ff0 0000 0000 0000 = Inf
  # 0x fff0 0000 0000 0000 = -Inf
  # 0x 7ff0 0000 0000 0001 <= nan <= 0x 7ff7 ffff ffff ffff signalling NaN
  # 0x fff0 0000 0000 0001 <= nan <= 0x fff7 ffff ffff ffff
  # 0x 7ff8 0000 0000 0000 <= nan <= 0x 7ff7 ffff ffff ffff quiet NaN
  # 0x fff8 0000 0000 0000 <= nan <= 0x ffff ffff ffff ffff
  #
  my Bool $six-byte-zeros = True;

  for ^6 -> $i {
    if ? $b[$index + $i] {
      $six-byte-zeros = False;
      last;
    }
  }
#say "Dbl 1: $six-byte-zeros";

  my Num $value;
  if $six-byte-zeros and $b[$index + 6] == 0 {
    if $b[$index + 7] == 0 {
      $value .= new(0);
    }

    elsif $b[$index + 7] == 0x80 {
      $value .= new(-0);
    }
  }

  elsif $six-byte-zeros and $b[$index + 6] == 0xF0 {
    if $b[$index + 7] == 0x7F {
      $value .= new(Inf);
    }

    elsif $b[$index + 7] == 0xFF {
      $value .= new(-Inf);
    }
  }

  elsif $b[$index + 7] == 0x7F and (0xf0 <= $b[$index + 6] <= 0xf7
        or 0xf8 <= $b[$index + 6] <= 0xff) {
    $value .= new(NaN);
  }

  elsif $b[$index + 7] == 0xFF and (0xf0 <= $b[$index + 6] <= 0xf7
        or 0xf8 <= $b[$index + 6] <= 0xff) {
    $value .= new(NaN);
  }

  # If value is not set by the special cases above, calculate it here
  #
  if !$value.defined {

    my Int $i = decode-int64( $b, $index);
    my Int $sign = $i +& 0x8000_0000_0000_0000 ?? -1 !! 1;

    # Significand + implicit bit
    #
    my $significand = 0x10_0000_0000_0000 +| ($i +& 0xF_FFFF_FFFF_FFFF);

    # Exponent - bias (1023) - the number of bits for precision
    #
    my $exponent = (($i +& 0x7FF0_0000_0000_0000) +> 52) - 1023 - 52;

    $value = Num.new((2 ** $exponent) * $significand * $sign);
  }

  return $value;
}

=finish
