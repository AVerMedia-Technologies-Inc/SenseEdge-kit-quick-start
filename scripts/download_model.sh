#!/bin/bash

#===============================================================================
#
#                         MODEL DOWNLOAD AND CONVERSION SCRIPT
#                             for SenseEdge Kit
#
#===============================================================================
#
# Description: This script downloads a YOLOv11n model, converts it to ONNX, 
#              and then to a TensorRT engine for the SenseEdge Kit project.
#
# Prerequisites:
#   - A virtual environment named 'realsense_env' must be active.
#   - The 'ultralytics' package must be installed.
#   - TensorRT tools must be available (e.g., via JetPack installation).
#
# Usage:
#   ./download_model.sh [OPTIONS]
#
# Options:
#   -h, --help       Show this help message and exit.
#   -l, --log        Save all output to a timestamped log file.
#
#===============================================================================

# Exit immediately if a command exits with a non-zero status.
set -e

# --- Configuration ---
readonly VENV_PATH="$HOME/aver/realsense_env"
# Determine project root (assuming this script is in <PROJECT_ROOT>/scripts)
readonly PROJECT_ROOT=$(dirname "$(dirname "$(readlink -f "$0")")") 
readonly MODELS_DIR="$PROJECT_ROOT/models"
readonly MODEL_NAME="yolo11n"
readonly PT_MODEL="$MODELS_DIR/$MODEL_NAME.pt"
readonly ONNX_MODEL="$MODELS_DIR/$MODEL_NAME.onnx"
readonly ENGINE_MODEL="$MODELS_DIR/$MODEL_NAME.engine"

# --- Global State & Step Variables ---
TOTAL_STEPS=5 # Corrected: Only 5 main operation steps
CURRENT_STEP=0
LOGGING_ENABLED=false
LOG_FILE=""

# Status tracking
VENV_ACTIVATED=false
ULTRALYTICS_INSTALLED=false
PT_DOWNLOADED=false
ONNX_CONVERTED=false
ENGINE_CONVERTED=false


# --- Utility Functions ---

detect_terminal_width() {
    local width=80
    if command -v tput >/dev/null 2>&1; then
        local tput_width
        tput_width=$(tput cols 2>/dev/null)
        if [ -n "$tput_width" ] && [ "$tput_width" -gt 0 ]; then
            width=$tput_width
        fi
    fi
    echo "$width"
}

init_terminal() {
    TERMINAL_WIDTH=$(detect_terminal_width)

    # Simplified color detection for this script
    if [ -t 1 ]; then
        readonly RED='\033[0;31m'
        readonly GREEN='\033[0;32m'
        readonly YELLOW='\033[1;33m'
        readonly BLUE='\033[0;34m'
        readonly PURPLE='\033[0;35m'
        readonly CYAN='\033[0;36m'
        readonly WHITE='\033[1;37m'
        readonly BOLD='\033[1m'
        readonly NC='\033[0m'
    else
        readonly RED=''
        readonly GREEN=''
        readonly YELLOW=''
        readonly BLUE=''
        readonly PURPLE=''
        readonly CYAN=''
        readonly WHITE=''
        readonly BOLD=''
        readonly NC=''
    fi

    readonly SUCCESS_SYMBOL="[OK]"
    readonly WARNING_SYMBOL="[WARNING]"
    readonly ERROR_SYMBOL="[ERROR]"
    readonly INFO_SYMBOL="[INFO]"
    # Using the same bullet symbol as setup.sh for consistency
    readonly BULLET_SYMBOL=" • " 
}

# --- Core Print Functions ---

print_banner() {
    local width_limit=$((TERMINAL_WIDTH > 80 ? 80 : TERMINAL_WIDTH))
    local line_char="━"
    local line=$(printf "%*s" $width_limit "" | tr ' ' "$line_char")

    local banner="\n"
    banner+="${BOLD}${CYAN}$line${NC}\n"
    banner+="\n"
    banner+="          ${BOLD}${WHITE}YOLOv11n MODEL DOWNLOAD AND CONVERSION${NC}\n"
    banner+="                           ${WHITE}for SenseEdge Kit${NC}\n"
    banner+="\n"
    banner+="${BOLD}${CYAN}$line${NC}\n"
    banner+="\n"
    printf "$banner"
}

print_step() {
    local format="$1"
    shift
    local text=$(printf "$format" "$@")
    CURRENT_STEP=$((CURRENT_STEP + 1))
    printf "\n${BOLD}${CYAN}[%d/%d] %s${NC}\n" "$CURRENT_STEP" "$TOTAL_STEPS" "$text"
}

print_success() {
    local format="$1"
    shift
    local text=$(printf "$format" "$@")
    printf "${GREEN}${SUCCESS_SYMBOL}${NC} %s\n" "$text"
}

print_warning() {
    local format="$1"
    shift
    local text=$(printf "$format" "$@")
    printf "${YELLOW}${WARNING_SYMBOL}${NC} %s\n" "$text"
}

print_error() {
    local format="$1"
    shift
    local text=$(printf "$format" "$@")
    printf "${RED}${ERROR_SYMBOL}${NC} %s\n" "$text"
}

print_info() {
    local format="$1"
    shift
    local text=$(printf "$format" "$@")
    printf "${CYAN}${INFO_SYMBOL}${NC} %s\n" "$text"
}

# --- Help and Argument Parsing ---

show_help() {
    cat << EOF
${BOLD}SenseEdge Kit Model Download and Conversion Script${NC}

USAGE:
    ./download_model.sh [OPTIONS]

OPTIONS:
    -h, --help      Show this help message and exit.
    -l, --log       Save the entire script output to a log file: download_model_[timestamp].log

DESCRIPTION:
    This script automates the download and conversion of the YOLOv11n model 
    (.pt -> .onnx -> .engine) for use with the SenseEdge Kit project.
    
    ${BULLET_SYMBOL} Activates the virtual environment (~/nvidia/aver/realsense_env).
    ${BULLET_SYMBOL} Ensures 'ultralytics' is installed.
    ${BULLET_SYMBOL} Downloads the yolo11n.pt file to the 'models' directory.
    ${BULLET_SYMBOL} Converts .pt to .onnx.
    ${BULLET_SYMBOL} Converts .onnx to TensorRT .engine using trtexec.

NOTE ON LICENSING:
    ${BULLET_SYMBOL} The YOLO model and the 'ultralytics' framework are typically 
      licensed under terms such as the AGPL-3.0 License. Users are responsible 
      for checking the official Ultralytics documentation for the specific 
      licensing requirements of the model version being used and ensuring compliance.

PREREQUISITES:
    ${BULLET_SYMBOL} Virtual environment must be prepared (run ${BOLD}setup.sh${NC} first).
    ${BULLET_SYMBOL} TensorRT tools must be available (JetPack installation).

EXAMPLES:
    # Run conversion with colored output
    ./scripts/download_model.sh

    # Run and save all output to a log file
    ./scripts/download_model.sh -l
EOF
}

parse_arguments() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -h|--help)
                show_help
                exit 0
                ;;
            -l|--log)
                LOGGING_ENABLED=true
                TIMESTAMP=$(date +%Y%m%d_%H%M%S)
                LOG_FILE="$PROJECT_ROOT/download_model_$TIMESTAMP.log"
                shift
                ;;
            *)
                print_error "Unknown option: %s" "$1"
                show_help
                exit 1
                ;;
        esac
    done
}


# --- Main Logic Functions ---

check_and_activate_venv() {
    print_step "Checking and Activating Virtual Environment (Venv)"

    if [ -d "$VENV_PATH" ]; then
        print_info "Virtual environment found: %s" "$VENV_PATH"
        source "$VENV_PATH/bin/activate"
        if [ "$?" -eq 0 ]; then
            print_success "Virtual environment activated: $VIRTUAL_ENV"
            VENV_ACTIVATED=true
            return 0
        else
            print_error "Failed to activate virtual environment"
            return 1
        fi
    else
        print_error "Virtual environment not found: %s" "$VENV_PATH"
        printf "  Please run ${BOLD}./setup.sh${NC} in the project root first.\n"
        return 1
    fi
}

check_and_install_ultralytics() {
    print_step "Checking and Installing ultralytics"

    if python -c "import ultralytics" &>/dev/null; then
        local version
        version=$(python -c "import ultralytics; print(ultralytics.__version__)")
        print_success "ultralytics module is already installed (Version: %s)" "$version"
        ULTRALYTICS_INSTALLED=true
    else
        print_warning "ultralytics module not found"
        print_info "Installing ultralytics via pip (This may take a few minutes)..."
        # Suppress installation logs using >/dev/null 2>&1
        if pip install ultralytics >/dev/null 2>&1; then 
            print_success "ultralytics installed successfully"
            ULTRALYTICS_INSTALLED=true
        else
            print_error "Failed to install ultralytics"
            return 1
        fi
    fi
    return 0
}

download_model() {
    print_step "Downloading Model File (.pt)"

    mkdir -p "$MODELS_DIR"
    
    if [ -f "$PT_MODEL" ]; then
        print_success "Model file already exists: %s" "$PT_MODEL"
        PT_DOWNLOADED=true
    else
        print_info "Downloading YOLOv11n pre-trained model (approx. 12 MB)..."
        # Suppress download logs using >/dev/null 2>&1
        if python -c "from ultralytics import YOLO; YOLO('$MODEL_NAME.pt').save('$PT_MODEL')" >/dev/null 2>&1; then
            if [ -f "$PT_MODEL" ]; then
                print_success "Model file downloaded successfully: %s" "$PT_MODEL"
                PT_DOWNLOADED=true
            else
                print_error "Model downloaded successfully, but file not found at expected path: %s" "$PT_MODEL"
                return 1
            fi
        else
            print_error "Failed to download model"
            return 1
        fi
    fi
    return 0
}

convert_to_onnx() {
    print_step "Converting Model to ONNX Format"

    if [ -f "$ONNX_MODEL" ]; then
        print_success "ONNX model already exists: %s" "$ONNX_MODEL"
        ONNX_CONVERTED=true
    elif [ "$PT_DOWNLOADED" = true ]; then
        print_info "Converting %s to ONNX..." "$MODEL_NAME.pt"
        # Suppress conversion logs using >/dev/null 2>&1
        if python -c "from ultralytics import YOLO; YOLO('$PT_MODEL').export(format='onnx', opset=17, imgsz=640)" >/dev/null 2>&1; then
            if [ -f "$ONNX_MODEL" ]; then
                print_success "ONNX model converted successfully: %s" "$ONNX_MODEL"
                ONNX_CONVERTED=true
            else
                print_error "ONNX conversion succeeded, but file not found at expected path: %s" "$ONNX_MODEL"
                return 1
            fi
        else
            print_error "Failed to convert ONNX model"
            return 1
        fi
    else
        print_warning "Skipping ONNX conversion because the .pt file does not exist."
    fi
    return 0
}

convert_to_tensorrt_engine() {
    print_step "Converting ONNX Model to TensorRT Engine"

    if [ -f "$ENGINE_MODEL" ]; then
        print_success "TensorRT Engine already exists: %s" "$ENGINE_MODEL"
        ENGINE_CONVERTED=true
    elif [ "$ONNX_CONVERTED" = true ]; then
        print_info "Converting %s to TensorRT Engine (fp16) using trtexec..." "$MODEL_NAME.onnx"
        
        TRTEXEC_PATH="/usr/src/tensorrt/bin/trtexec"
        if [ ! -f "$TRTEXEC_PATH" ]; then
            print_error "TensorRT executable not found: %s" "$TRTEXEC_PATH"
            printf "  Please ensure NVIDIA JetPack SDK is installed.\n"
            return 1
        fi
        
        local trtexec_cmd="$TRTEXEC_PATH --onnx=$ONNX_MODEL --fp16 --saveEngine=$ENGINE_MODEL"
        
        # Execute trtexec, suppressing all output unless it fails (exit code != 0)
        if $trtexec_cmd >/dev/null 2>&1; then
            if [ -f "$ENGINE_MODEL" ]; then
                print_success "TensorRT Engine converted successfully: %s" "$ENGINE_MODEL"
                ENGINE_CONVERTED=true
            else
                print_error "Engine conversion succeeded, but file not found at expected path: %s" "$ENGINE_MODEL"
                return 1
            fi
        else
            print_error "TensorRT Engine conversion failed. Check TensorRT installation and configuration."
            return 1
        fi
    else
        print_warning "Skipping Engine conversion because the ONNX file does not exist."
    fi
    return 0
}

print_summary() {
    printf "\n"
    # FIX: Use a descriptive header instead of a numbered step
    printf "${BOLD}${CYAN}--- Setup Summary ---${NC}\n"
    
    printf "\n"
    if [ "$VENV_ACTIVATED" = true ]; then
        printf "  ${GREEN}[O]${NC} Virtual environment activated\n"
    else
        printf "  ${RED}[X]${NC} Virtual environment activation failed\n"
    fi
    
    if [ "$ULTRALYTICS_INSTALLED" = true ]; then
        printf "  ${GREEN}[O]${NC} ultralytics installed\n"
    else
        printf "  ${RED}[X]${NC} ultralytics installation failed\n"
    fi

    if [ "$PT_DOWNLOADED" = true ]; then
        printf "  ${GREEN}[O]${NC} .pt Model file ready: ${PT_MODEL}\n"
    else
        printf "  ${RED}[X]${NC} .pt Model file download failed\n"
    fi

    if [ "$ONNX_CONVERTED" = true ]; then
        printf "  ${GREEN}[O]${NC} ONNX Model file ready: ${ONNX_MODEL}\n"
    else
        printf "  ${RED}[X]${NC} ONNX Model file conversion failed\n"
    fi

    if [ "$ENGINE_CONVERTED" = true ]; then
        printf "  ${GREEN}[O]${NC} TensorRT Engine file ready: ${ENGINE_MODEL}\n"
    else
        printf "  ${RED}[X]${NC} TensorRT Engine conversion failed\n"
    fi
    
    printf "\n"
}

# --- Main Execution Function ---

main() {
    print_banner

    # Step 1: Check and Activate Venv
    if ! check_and_activate_venv; then
        print_summary
        print_error "Model setup aborted: Virtual environment failed to activate."
        exit 1
    fi

    # Step 2: Check and Install ultralytics
    if ! check_and_install_ultralytics; then
        print_summary
        print_error "Model setup aborted: ultralytics installation failed."
        exit 1
    fi

    # Step 3: Download .pt model
    if ! download_model; then
        print_summary
        print_error "Model setup aborted: .pt model download failed."
        exit 1
    fi

    # Step 4: Convert to ONNX
    if ! convert_to_onnx; then
        print_summary
        print_error "Model setup aborted: ONNX model conversion failed."
        exit 1
    fi

    # Step 5: Convert to TensorRT Engine
    if ! convert_to_tensorrt_engine; then
        print_summary
        print_error "Model setup aborted: TensorRT Engine conversion failed."
        exit 1
    fi

    # Final Summary
    print_summary
    printf "${GREEN}SenseEdge Kit Model Development Setup completed successfully!${NC}\n"

    # Deactivate venv if it was activated by this script
    if [ "$VENV_ACTIVATED" = true ]; then
        deactivate
    fi

    exit 0
}

# --- Script Initialization and Execution ---

init_terminal
parse_arguments "$@"

# Logging wrapper logic
if [ "$LOGGING_ENABLED" = true ]; then
    # Print the logging announcement to the terminal before redirection
    print_info "Logging enabled. All output will be saved to: $LOG_FILE"
    
    # Save current STDOUT and STDERR to FD 3 and 4
    exec 3>&1 4>&2
    
    # Redirect STDOUT (1) to tee, which prints to original STDOUT (FD 3) and the log file
    exec 1> >(tee -a "$LOG_FILE")
    
    # Redirect STDERR (2) to STDOUT (1) so that all errors also go through tee
    exec 2>&1
    
    # Run the main script
    main
    
    # Wait for the background tee process to finish writing
    wait
    
    # Restore original STDOUT and STDERR (not strictly needed since main exits, but good practice)
    exec 1>&3 3>&-
    exec 2>&4 4>&-
    
else
    # Run without logging
    main
fi
