#!/bin/sh
# Run a C/C++ program inside the sim30 simulator shipped with XC16
#   Usage: ./compile_and_sim30.sh <source-files...>
# If at least one C++ file is present, C++ support files are automatically
# linked in too.
# The XC16DIR environment variable must be set, e.g.
#   XC16DIR=/opt/microchip/xc16/v1.23

function to_native_path()
{
	if uname | grep -q CYGWIN;
	then
		cygpath -w "$1"
	else
		echo "$1"
	fi
}

THISDIR="$(cd "$(dirname "$0")" && pwd)"
SUPPORTFILESDIR="$(to_native_path "$THISDIR/../support-files")"

if [ "$XC16DIR" == "" ];
then
	echo "Error: \$XC16DIR is not set!" >&2
	exit 1
fi

if [ "$TARGET_CHIP" == "" ];
then
	echo "Error: \$TARGET_CHIP is not set!" >&2
	exit 1
fi

if [ "$TARGET_FAMILY" == "" ];
then
	echo "Error: \$TARGET_FAMILY is not set!" >&2
	exit 1
fi

if [ "$SIM30_DEVICE" == "" ];
then
	echo "Error: \$SIM30_DEVICE is not set!" >&2
	exit 1
fi

if [ "$OMF" != "coff" ] && [ "$OMF" != "elf" ];
then
	echo "Error: \$OMF is not set or it is neither \"coff\" nor \"elf\"!" >&2
	exit 1
fi

CFLAGS=(-omf=$OMF -mno-eds-warn -no-legacy-libc -mcpu="$TARGET_CHIP")
CXXFLAGS=("${CFLAGS[@]}" -I$SUPPORTFILESDIR -fno-exceptions -fno-rtti -D__bool_true_and_false_are_defined -std=gnu++0x)
LDSCRIPT="$XC16DIR/support/$TARGET_FAMILY/gld/p$TARGET_CHIP.gld"
LDFLAGS=(-omf=$OMF --local-stack -p"$TARGET_CHIP" --report-mem --script "$LDSCRIPT" --heap=512 -L"$XC16DIR/lib" -L"$XC16DIR/lib/$TARGET_FAMILY")
LIBS=(-lc -lpic30 -lm)

function __verboserun()
{
	echo "+ $@" >&2
	"$@"
}

set -e
TEMPDIR=$(mktemp -d -t compile_and_sim30.XXXXXXX)
trap "rm -rf '$TEMPDIR'" exit

declare -a OBJFILES
CXX_SUPPORT_FILES=false

for SRCFILE in "$@";
do
	case "$SRCFILE" in
		*.c)
			__verboserun "$XC16DIR/bin/xc16-gcc" "${CFLAGS[@]}" \
				-c -o "$(to_native_path "$TEMPDIR/$SRCFILE.o")" \
					"$(to_native_path "$SRCFILE")"
			OBJFILES+=("$(to_native_path "$TEMPDIR/$SRCFILE.o")")
			;;
		*.cpp)
			if ! $CXX_SUPPORT_FILES;
			then
				CXX_SUPPORT_FILES=true
				__verboserun "$XC16DIR/bin/xc16-g++" \
					"${CXXFLAGS[@]}" -c -o \
					"$(to_native_path "$TEMPDIR/minilibstdc++.o")" \
					"$(to_native_path "$SUPPORTFILESDIR/minilibstdc++.cpp")"
				OBJFILES+=("$(to_native_path "$TEMPDIR/minilibstdc++.o")")
			fi
			mkdir -p "$(dirname "$TEMPDIR/$SRCFILE.o")"
			__verboserun "$XC16DIR/bin/xc16-g++" "${CXXFLAGS[@]}" \
				-c -o "$(to_native_path "$TEMPDIR/$SRCFILE.o")" \
					"$(to_native_path "$SRCFILE")"
			OBJFILES+=("$(to_native_path "$TEMPDIR/$SRCFILE.o")")
			;;
	esac
done

__verboserun "$XC16DIR/bin/xc16-ld" "${LDFLAGS[@]}" \
	-o "$(to_native_path "$TEMPDIR/result.elf")" \
	"${OBJFILES[@]}" "${LIBS[@]}" \
	--save-gld="$(to_native_path "$TEMPDIR/gld")" >&2
__verboserun "$XC16DIR/bin/xc16-bin2hex" -omf=$OMF "$(to_native_path "$TEMPDIR/result.elf")"

cat > "$TEMPDIR/sim30-script" << EOF
ld $SIM30_DEVICE
lp $(to_native_path "$TEMPDIR/result.hex")
rp
io nul $(to_native_path "$TEMPDIR/output.txt")
e
q
EOF

set +e
__verboserun perl -e 'alarm 10; exec @ARGV' "$XC16DIR/bin/sim30" \
	"$(to_native_path "$TEMPDIR/sim30-script")" >&2
case "$?" in
	0)
		echo "sim30 succeeded!" >&2
		# The apparently useless sed invocation is a trick to normalize
		# line endings when running on windows/cygwin
		sed 's/a/a/' "$TEMPDIR/output.txt"
		;;
	142)
		echo "Simulation timed out (killed after 10 seconds)"
		exit 1
		;;
	*)
		exit 1
		;;
esac
