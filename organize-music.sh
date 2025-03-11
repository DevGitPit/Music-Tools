#!/bin/bash

# Check if required tools are installed
if ! command -v ffprobe &> /dev/null; then
    echo "Error: ffprobe is not installed. Please install ffmpeg package in Termux."
    exit 1
fi

if ! command -v jq &> /dev/null; then
    echo "Error: jq is not installed. Please install jq package in Termux."
    exit 1
fi

# Array of common audio file extensions
audio_extensions=("mp3" "m4a" "flac" "wav" "ogg" "aac" "opus")
selected_extensions=()

# Help function
show_help() {
    echo "Usage: $0 [OPTIONS] <directory_path>"
    echo
    echo "Options:"
    echo "  -h, --help               Show this help message"
    echo "  -a, --all                Process all audio formats (default)"
    echo "  -i, --interactive        Interactive mode to select formats"
    echo "  -f FORMAT, --format=FORMAT  Process only specified format"
    echo "                           (can be used multiple times)"
    echo
    echo "Supported formats: ${audio_extensions[*]}"
    echo
    echo "Examples:"
    echo "  $0 /path/to/music        # Process all audio formats"
    echo "  $0 -f mp3 /path/to/music # Process only MP3 files"
    echo "  $0 -f flac -f opus /path/to/music # Process FLAC and OPUS files"
    echo "  $0 -i /path/to/music     # Select formats interactively"
    exit 0
}

# Function to check if file matches selected extensions
is_selected_format() {
    local file="$1"
    local ext="${file##*.}"
    ext="${ext,,}"  # Convert to lowercase
    
    # If no specific formats are selected, check against all supported formats
    if [ ${#selected_extensions[@]} -eq 0 ]; then
        for valid_ext in "${audio_extensions[@]}"; do
            if [[ "$ext" == "$valid_ext" ]]; then
                return 0
            fi
        done
    else
        # Otherwise, check against selected formats
        for valid_ext in "${selected_extensions[@]}"; do
            if [[ "$ext" == "$valid_ext" ]]; then
                return 0
            fi
        done
    fi
    return 1
}

# Enhanced sanitize function to handle more edge cases
sanitize_path() {
    local input="$1"
    # Remove carriage returns and other problematic characters
    local sanitized=$(echo "$input" | tr -d '\r' | tr -d '\n' | tr -d '\t')
    # Replace forward slashes with dashes to prevent directory traversal
    sanitized=$(echo "$sanitized" | tr '/' '-')
    # Remove other problematic characters
    sanitized=$(echo "$sanitized" | tr -d '/<>:"|?*\\')
    # Trim leading/trailing whitespace
    sanitized=$(echo "$sanitized" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    # Replace multiple spaces with single space
    sanitized=$(echo "$sanitized" | tr -s ' ')
    # If sanitized string is empty, return "Unknown"
    if [ -z "$sanitized" ]; then
        echo "Unknown"
    else
        echo "$sanitized"
    fi
}

# Function to extract and process metadata with improved error handling
process_file() {
    local file="$1"
    local format_json
    local stream_json
    
    # Use timeout to prevent hanging on corrupted files
    format_json=$(timeout 10s ffprobe -v quiet -show_entries format_tags=Artist,Album -print_format json "$file") || {
        echo "Error: Failed to extract format metadata from: $file"
        return 1
    }
    
    stream_json=$(timeout 10s ffprobe -v quiet -show_entries stream_tags=Artist,Album -print_format json "$file") || {
        echo "Error: Failed to extract stream metadata from: $file"
        return 1
    }
    
    # Extract values using jq with null checks and improved error handling
    # Format tags - check for all case variations
    local format_artist=$(echo "$format_json" | jq -r '
        if .format.tags then
            .format.tags | 
            with_entries(.key |= ascii_downcase) |
            .artist // .Artist // .ARTIST // empty
        else empty end
    ')
    local format_album=$(echo "$format_json" | jq -r '
        if .format.tags then
            .format.tags | 
            with_entries(.key |= ascii_downcase) |
            .album // .Album // .ALBUM // empty
        else empty end
    ')
    
    # Stream tags - check all streams and all case variations
    local stream_artist=$(echo "$stream_json" | jq -r '
        [.streams[]?.tags? | 
        select(. != null) |
        with_entries(.key |= ascii_downcase) |
        .artist // .Artist // .ARTIST // empty] |
        map(select(length > 0))[0] // empty
    ')
    local stream_album=$(echo "$stream_json" | jq -r '
        [.streams[]?.tags? | 
        select(. != null) |
        with_entries(.key |= ascii_downcase) |
        .album // .Album // .ALBUM // empty] |
        map(select(length > 0))[0] // empty
    ')
    
    # Use format tags if available, otherwise try stream tags
    local artist="${format_artist:-$stream_artist}"
    local album="${format_album:-$stream_album}"
    
    # Use "Unknown" as fallback if metadata is missing
    artist="${artist:-Unknown Artist}"
    album="${album:-Unknown Album}"
    
    # Sanitize artist and album names for safe path creation
    local safe_artist=$(sanitize_path "$artist")
    local safe_album=$(sanitize_path "$album")
    
    # Create target directory with error handling
    local target_dir="$safe_artist/$safe_album"
    if ! mkdir -p "$target_dir"; then
        echo "Error: Failed to create directory: $target_dir"
        return 1
    fi
    
    # Get just the filename from the full path and sanitize it
    local filename=$(basename "$file")
    local safe_filename=$(sanitize_path "$filename")
    
    # If filename ends up empty after sanitization, use original filename
    if [ -z "$safe_filename" ]; then
        safe_filename="$filename"
    fi
    
    # Ensure file extension is preserved
    local extension="${filename##*.}"
    safe_filename="${safe_filename%.*}.${extension}"
    
    # Check if source and destination are different
    if [ "$file" = "$target_dir/$safe_filename" ]; then
        echo "Skip: File already in correct location: $file"
        return 0
    fi
    
    # Move the file with error handling
    if ! mv -f "$file" "$target_dir/$safe_filename"; then
        echo "Error: Failed to move: $filename -> $target_dir/$safe_filename"
        # Try copying instead
        if cp "$file" "$target_dir/$safe_filename"; then
            rm "$file" && echo "Success: Copied and removed: $filename -> $target_dir/$safe_filename" || echo "Warning: File copied but original couldn't be removed: $file"
        else
            echo "Error: Both move and copy failed for: $file"
            return 1
        fi
    else
        echo "Success: Moved: $filename -> $target_dir/$safe_filename"
    fi
}

# Function to count files of each format in a directory
count_format_files() {
    local dir="$1"
    local counts=()
    
    for ext in "${audio_extensions[@]}"; do
        local count=$(find "$dir" -maxdepth 1 -type f -iname "*.${ext}" | wc -l)
        if [ "$count" -gt 0 ]; then
            counts+=("$ext: $count")
        fi
    done
    
    echo "${counts[*]}"
}

# Interactive mode to select formats
interactive_select() {
    local dir="$1"
    local format_counts=$(count_format_files "$dir")
    
    echo "Available audio formats in directory (counts):"
    echo "0: All formats (default)"
    
    local i=1
    local valid_indexes=()
    for ext in "${audio_extensions[@]}"; do
        local count=$(find "$dir" -maxdepth 1 -type f -iname "*.${ext}" | wc -l)
        if [ "$count" -gt 0 ]; then
            echo "$i: $ext ($count files)"
            valid_indexes+=("$i")
        fi
        i=$((i+1))
    done
    
    read -p "Enter format number(s) to process (separate multiple selections with space): " -a selections
    
    # If no selection or 0 is chosen, use all formats
    if [ ${#selections[@]} -eq 0 ] || [[ " ${selections[*]} " =~ " 0 " ]]; then
        echo "Processing all audio formats"
        return
    fi
    
    # Process valid selections
    for selection in "${selections[@]}"; do
        if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -gt 0 ] && [ "$selection" -le ${#audio_extensions[@]} ]; then
            index=$((selection-1))
            selected_extensions+=("${audio_extensions[$index]}")
        fi
    done
    
    if [ ${#selected_extensions[@]} -eq 0 ]; then
        echo "No valid formats selected. Using all formats."
    else
        echo "Selected formats: ${selected_extensions[*]}"
    fi
}

# Parse command line arguments
interactive_mode=false
directory=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        -h|--help)
            show_help
            ;;
        -a|--all)
            selected_extensions=()
            shift
            ;;
        -i|--interactive)
            interactive_mode=true
            shift
            ;;
        -f|--format)
            if [ -n "$2" ] && [[ ! "$2" =~ ^- ]]; then
                format="${2,,}"  # Convert to lowercase
                if [[ " ${audio_extensions[*]} " =~ " $format " ]]; then
                    selected_extensions+=("$format")
                else
                    echo "Warning: Unsupported format '$format'. Ignoring."
                fi
                shift 2
            else
                echo "Error: Missing format argument for -f/--format"
                exit 1
            fi
            ;;
        --format=*)
            format="${1#*=}"
            format="${format,,}"  # Convert to lowercase
            if [[ " ${audio_extensions[*]} " =~ " $format " ]]; then
                selected_extensions+=("$format")
            else
                echo "Warning: Unsupported format '$format'. Ignoring."
            fi
            shift
            ;;
        -*)
            echo "Error: Unknown option: $1"
            show_help
            ;;
        *)
            if [ -z "$directory" ]; then
                directory="$1"
            else
                echo "Error: Multiple directories specified"
                show_help
            fi
            shift
            ;;
    esac
done

# Validate input directory
if [ -z "$directory" ]; then
    echo "Error: Please provide a directory path"
    show_help
fi

if [ ! -d "$directory" ]; then
    echo "Error: Directory does not exist: $directory"
    exit 1
fi

# Run interactive mode if selected
if [ "$interactive_mode" = true ]; then
    interactive_select "$directory"
fi

# Display processing information
if [ ${#selected_extensions[@]} -eq 0 ]; then
    echo "Processing all audio formats in: $directory"
else
    echo "Processing formats [${selected_extensions[*]}] in: $directory"
fi

# Find and process audio files in directory
found_files=0
processed_files=0

for file in "$directory"/*; do
    if [[ -f "$file" ]] && is_selected_format "$file"; then
        found_files=$((found_files+1))
        if process_file "$file"; then
            processed_files=$((processed_files+1))
        fi
    fi
done

# Summary
if [ $found_files -eq 0 ]; then
    echo "No matching audio files found in directory: $directory"
else
    echo "Summary: Processed $processed_files out of $found_files audio files"
fi

exit 0
