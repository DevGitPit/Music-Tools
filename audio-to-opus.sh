#!/bin/bash

# Initialize arrays for tracking files
declare -a all_source_files
declare -a opusenc_failed
declare -a ffmpeg_failed
declare -a already_converted
declare -a skipped_files

# Supported input formats
readonly SUPPORTED_FORMATS=("flac" "wav" "m4a" "alac" "aiff" "ape" "wv")

# Default bitrate
BITRATE=256
# Default processing depth
MAXDEPTH=1

# Process command line arguments
while getopts ":b:d:h" opt; do
  case ${opt} in
    b )
      if [[ $OPTARG =~ ^[0-9]+$ ]] && [ $OPTARG -ge 32 ] && [ $OPTARG -le 512 ]; then
        BITRATE=$OPTARG
      else
        echo "Error: Bitrate must be between 32 and 512 kbps"
        exit 1
      fi
      ;;
    d )
      if [[ $OPTARG =~ ^[0-9]+$ ]] && [ $OPTARG -ge 1 ]; then
        MAXDEPTH=$OPTARG
      else
        echo "Error: Depth must be a positive integer"
        exit 1
      fi
      ;;
    h )
      echo "Usage: $0 [-b bitrate] [-d depth] [-h]"
      echo "  -b bitrate: Set the encoding bitrate (32-512 kbps, default: 256)"
      echo "  -d depth: Set the directory search depth (default: 1)"
      echo "  -h: Display this help message"
      exit 0
      ;;
    \? )
      echo "Invalid option: -$OPTARG" 1>&2
      exit 1
      ;;
    : )
      echo "Option -$OPTARG requires an argument" 1>&2
      exit 1
      ;;
  esac
done

# Function to check if OPUS file is valid (exists and has size > 0)
check_opus() {
    local opus_file="$1"
    if [ -f "$opus_file" ] && [ -s "$opus_file" ]; then
        return 0
    fi
    return 1
}

# Function to get audio bitrate using ffprobe
get_audio_bitrate() {
    local file="$1"
    local bitrate=$(ffprobe -v error -select_streams a:0 -show_entries stream=bit_rate -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null)
    
    # If bitrate is in bits per second, convert to kbps
    if [[ -n "$bitrate" ]]; then
        # Check if bitrate is in bits per second
        if [[ "$bitrate" -gt 1000 ]]; then
            bitrate=$((bitrate / 1000))
        fi
        echo "$bitrate"
    else
        echo "0"
    fi
}

# Function to check if file should be skipped (for m4a files)
should_skip_conversion() {
    local file="$1"
    local ext="${file##*.}"
    ext="${ext,,}"  # Convert to lowercase
    
    # Only apply bitrate check for m4a files
    if [[ "$ext" == "m4a" ]]; then
        local bitrate=$(get_audio_bitrate "$file")
        
        # Skip if bitrate is close to target (within +/- 20 kbps)
        if [[ -n "$bitrate" ]] && [[ "$bitrate" -ge $((BITRATE - 20)) ]] && [[ "$bitrate" -le $((BITRATE + 20)) ]]; then
            return 0  # Skip conversion
        fi
    fi
    return 1  # Do not skip
}

# Function to collect all supported audio files
collect_audio_files() {
    local files=()
    for format in "${SUPPORTED_FORMATS[@]}"; do
        while IFS= read -r -d '' file; do
            # Skip files that are in the backup directory
            if [[ "$file" != *"$backup_dir"* ]]; then
                files+=("$file")
            fi
        done < <(find . -maxdepth "$MAXDEPTH" -type f -iname "*.$format" -print0 2>/dev/null)
    done
    printf '%s\0' "${files[@]}"
}

# Function to safely remove a file
safe_remove() {
    local file="$1"
    if [ -f "$file" ]; then
        rm -- "$file"
    fi
}

# Check for required tools
check_requirements() {
    local missing_tools=()
    
    if ! command -v opusenc >/dev/null 2>&1; then
        missing_tools+=("opusenc (from opus-tools package)")
    fi
    
    if ! command -v ffmpeg >/dev/null 2>&1; then
        missing_tools+=("ffmpeg")
    fi
    
    if ! command -v parallel >/dev/null 2>&1; then
        missing_tools+=("parallel")
    fi
    
    if ! command -v ffprobe >/dev/null 2>&1; then
        missing_tools+=("ffprobe (from ffmpeg package)")
    fi
    
    if [ ${#missing_tools[@]} -gt 0 ]; then
        echo "Error: The following required tools are missing:"
        for tool in "${missing_tools[@]}"; do
            echo "  - $tool"
        done
        echo "Please install them and try again."
        exit 1
    fi
}

# Trap for cleanup on exit
cleanup() {
    # If the script is interrupted, make sure no temporary files are left
    if [ -n "$temp_dir" ] && [ -d "$temp_dir" ]; then
        rm -rf "$temp_dir"
    fi
    echo -e "\nScript interrupted. Cleaning up..."
    exit 1
}

trap cleanup INT TERM

# Check for required tools
check_requirements

# Create a temporary directory for logs
temp_dir=$(mktemp -d)
if [ ! -d "$temp_dir" ]; then
    echo "Error: Failed to create temporary directory"
    exit 1
fi

# First pass: Check for existing opus files
echo "Checking for existing OPUS files..."
echo "-----------------------------------"

# Create backup directory only if opus files are found
backup_dir="opus_backup_$(date +%Y%m%d_%H%M%S)"
has_existing_opus=false

# Collect all supported audio files
mapfile -d $'\0' all_source_files < <(collect_audio_files)

if [ ${#all_source_files[@]} -eq 0 ]; then
    echo "No supported audio files found in current directory (depth: $MAXDEPTH)."
    echo "Supported formats: ${SUPPORTED_FORMATS[*]}"
    exit 1
fi

total_files=${#all_source_files[@]}
echo "Found $total_files audio files to process using bitrate: ${BITRATE}kbps"
echo

# Check for existing opus files and back them up if found
for source in "${all_source_files[@]}"; do
    opus="${source%.*}.opus"
    if check_opus "$opus"; then
        if ! $has_existing_opus; then
            has_existing_opus=true
            mkdir -p "$backup_dir"
        fi
        mv -- "$opus" "$backup_dir/"
        already_converted+=("$source")
        echo "Backed up existing: $opus"
    fi
done

echo
if $has_existing_opus; then
    echo "Backed up ${#already_converted[@]} existing OPUS files to $backup_dir"
else
    echo "No existing OPUS files found. No backup needed."
fi
echo

# Prepare files to skip and process
skipped_files_file="$temp_dir/skipped_files.txt"
touch "$skipped_files_file"

# Identify files to skip
for source in "${all_source_files[@]}"; do
    if should_skip_conversion "$source"; then
        echo "$source" >> "$skipped_files_file"
    fi
done

# Read skipped files
mapfile -t skipped_files < "$skipped_files_file"

# Prepare list of processable files
processable_files=()
for source in "${all_source_files[@]}"; do
    if ! grep -qxF "$source" "$skipped_files_file"; then
        processable_files+=("$source")
    fi
done

# First pass: opusenc conversion using parallel
echo "Starting first pass with opusenc (parallel processing)..."
echo "--------------------------------------------------"
echo "Converting all possible files with opusenc..."

# Export function for parallel to use
export -f check_opus
export -f safe_remove
export -f should_skip_conversion
export -f get_audio_bitrate
export BITRATE
export temp_dir

# Create a known error file for ffmpeg failures
opusenc_error_file="$temp_dir/opusenc_errors.txt"
touch "$opusenc_error_file"

# Parallel opusenc conversion
parallel --will-cite 'source_file={1}; opus_file=${source_file%.*}.opus; ext="${source_file##*.}"; ext="${ext,,}"; if [[ "$ext" == "flac" ]] || [[ "$ext" == "wav" ]]; then if opusenc --vbr --bitrate $BITRATE "$source_file" "$opus_file" 2>"$temp_dir/$(basename "$source_file").err"; then if ! check_opus "$opus_file"; then safe_remove "$opus_file"; echo "$source_file" >> "$temp_dir/opusenc_errors.txt"; fi; else safe_remove "$opus_file"; echo "$source_file" >> "$temp_dir/opusenc_errors.txt"; fi; else echo "$source_file" >> "$temp_dir/opusenc_errors.txt"; fi' ::: "${processable_files[@]}"

# Read the error file to get failed conversions
mapfile -t opusenc_failed < "$temp_dir/opusenc_errors.txt"

# Second pass: ffmpeg fallback using parallel
if [ ${#opusenc_failed[@]} -gt 0 ]; then
    echo
    echo "Starting second pass with ffmpeg (parallel processing)..."
    echo "---------------------------------------------------"
    echo "Found ${#opusenc_failed[@]} files to process with ffmpeg."
    echo

    # Create a known error file for ffmpeg failures
    ffmpeg_error_file="$temp_dir/ffmpeg_errors.txt"
    touch "$ffmpeg_error_file"

    # Parallel ffmpeg conversion for remaining files
    parallel --will-cite 'source_file={1}; opus_file=${source_file%.*}.opus; if ffmpeg -v error -i "$source_file" -c:a libopus -b:a ${BITRATE}k -vbr on -application audio "$opus_file" 2>"$temp_dir/ffmpeg_$(basename "$source_file").err"; then if ! check_opus "$opus_file"; then safe_remove "$opus_file"; echo "$source_file" >> "$temp_dir/ffmpeg_errors.txt"; fi; else safe_remove "$opus_file"; echo "$source_file" >> "$temp_dir/ffmpeg_errors.txt"; fi' ::: "${opusenc_failed[@]}"

    # Read the error file to get failed conversions
    mapfile -t ffmpeg_failed < "$ffmpeg_error_file"
else
    ffmpeg_failed=()
fi

# Final statistics
echo
echo "Conversion Summary"
echo "-----------------"
echo "Total audio files found: $total_files"
echo "Previously converted files (backed up): ${#already_converted[@]}"
echo "Skipped files (near target bitrate): ${#skipped_files[@]}"

total_processable=$((total_files - ${#skipped_files[@]}))
opusenc_success_count=$((total_processable - ${#opusenc_failed[@]} - ${#already_converted[@]}))
ffmpeg_success_count=$(( ${#opusenc_failed[@]} - ${#ffmpeg_failed[@]} ))

echo "Successfully converted with opusenc: $opusenc_success_count"
echo "Successfully converted with ffmpeg: $ffmpeg_success_count"
echo "Total failed conversions: ${#ffmpeg_failed[@]}"

# List failed files if any
if [ ${#ffmpeg_failed[@]} -gt 0 ]; then
    echo
    echo "Files that could not be converted:"
    echo "---------------------------------"
    printf '%s\n' "${ffmpeg_failed[@]}"
    
    # Offer to show error logs
    read -p "Do you want to see detailed error logs? (y/n): " show_logs
    if [[ $show_logs =~ ^[Yy]$ ]]; then
        for file in "${ffmpeg_failed[@]}"; do
            basename=$(basename "$file")
            echo -e "\nErrors for $basename:"
            if [ -f "$temp_dir/ffmpeg_$basename.err" ]; then
                cat "$temp_dir/ffmpeg_$basename.err"
            elif [ -f "$temp_dir/$basename.err" ]; then
                cat "$temp_dir/$basename.err"
            else
                echo "No detailed error log available"
            fi
        done
    fi
fi

# List skipped files if any
if [ ${#skipped_files[@]} -gt 0 ]; then
    echo
    echo "Skipped files (near target bitrate):"
    echo "-----------------------------------"
    printf '%s\n' "${skipped_files[@]}"
fi

# Provide restore instructions only if backups were created
if $has_existing_opus; then
    echo
    echo "Your previous OPUS files were backed up to: $backup_dir"
    echo "To restore them, use: mv \"$backup_dir\"/*.opus ."
fi

# Clean up temporary files
rm -rf "$temp_dir"

# Exit with status based on failures
if [ ${#ffmpeg_failed[@]} -gt 0 ]; then
    echo
    echo "Some files failed to convert. See the list above."
    exit 1
else
    echo
    echo "All convertible files processed successfully."
    exit 0
fi
