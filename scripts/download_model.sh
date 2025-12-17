#!/bin/bash

#===============================================================================
#
#                         MODEL DOWNLOAD AND CONVERSION SCRIPT
#                             for SenseEdge Kit
#
#===============================================================================

set -e
set -u 
set -o pipefail 

# --- Configuration ---
readonly VENV_SUB_DIR="avermedia"
readonly VENV_NAME="realsense_env"
# Determine project root (assuming this script is in <PROJECT_ROOT>/scripts)
readonly PROJECT_ROOT=$(dirname "$(dirname "$(readlink -f "$0")")") 
readonly MODELS_DIR="$PROJECT_ROOT/models"
readonly MODEL_NAME="yolo11n"
readonly PT_MODEL="$MODELS_DIR/$MODEL_NAME.pt"
readonly ONNX_MODEL="$MODELS_DIR/$MODEL_NAME.onnx"
readonly ENGINE_MODEL="$MODELS_DIR/$MODEL_NAME.engine"

# Derive VENV path
readonly VENV_PATH="$HOME/$VENV_SUB_DIR/$VENV_NAME"

# Global configuration
USE_COLORS=true
LOG_ENABLED=false
LOG_FILE="./download_model_$(date +%Y%m%d_%H%M%S).log"
readonly DEV_NULL="/dev/null"

# Step variables
TOTAL_STEPS=5 
CURRENT_STEP=0

# Status tracking
VENV_ACTIVATED=false
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

detect_color_support() {
    # Fix: Use ${NO_COLOR:-} to handle unbound variable error when set -u is active
    if [ "$USE_COLORS" = false ] || [ ! -t 1 ] || [ -n "${NO_COLOR:-}" ]; then
        return 1
    fi
    if command -v tput >/dev/null 2>&1 && [ "$(tput colors 2>/dev/null)" -ge 8 ]; then
        return 0
    fi
    return 1
}

init_terminal() {
    TERMINAL_WIDTH=$(detect_terminal_width)

    if detect_color_support; then
        # Use $'...' to ensure variables contain the actual escape character
        readonly RED=$'\033[0;31m'
        readonly GREEN=$'\033[0;32m'
        readonly YELLOW=$'\033[1;33m'
        readonly BLUE=$'\033[0;34m'
        readonly PURPLE=$'\033[0;35m'
        readonly CYAN=$'\033[0;36m'
        readonly WHITE=$'\033[1;37m'
        readonly BOLD=$'\033[1m'
        readonly NC=$'\033[0m'
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
    readonly BULLET_SYMBOL=" • " 
}

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

print_header() {
    local text="$1"
    printf "${BOLD}${CYAN}--- %s ${NC}\n" "$text"
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

get_log_target() {
    if [ "$LOG_ENABLED" = true ]; then
        echo "$LOG_FILE"
    else
        echo "$DEV_NULL"
    fi
}

# --- Core Functions (Matches setup.sh style) ---

run_command_log_error() {
    local description="$1"
    shift
    local command_to_run=("$@")
    local log_target=$(get_log_target)
    
    print_info "%s..." "$description"
    
    # Use array expansion for safety
    if ! "${command_to_run[@]}" >> "$log_target" 2>&1; then
        print_error "%s FAILED." "$description"
        if [ "$LOG_ENABLED" = true ]; then
            print_error "Check %s for details." "$LOG_FILE"
        fi
        return 1
    fi
    
    print_success "%s completed." "$description"
    return 0
}

# --- Help and Argument Parsing ---

show_help() {
    cat << EOF
${BOLD}SenseEdge Kit Model Download and Conversion Script${NC}

USAGE:
    ./download_model.sh [OPTIONS]

OPTIONS:
    -h, --help      Show this help message and exit.
    --no-color      Disable colored output
    -l, --log       Enable logging for verbose commands to download_model_[timestamp].log

DESCRIPTION:
    This script automates the download and conversion of the YOLOv11n model 
    (.pt -> .onnx -> .engine) for use with the SenseEdge Kit project.
EOF
}

parse_arguments() {
    while [ "$#" -gt 0 ]; do
        local param="$1"
        case "$param" in
            -h|--help)
                init_terminal
                show_help
                exit 0
                ;;
            --no-color)
                USE_COLORS=false
                shift
                ;;
            -l|--log)
                LOG_ENABLED=true
                shift
                ;;
            *)
                init_terminal
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
        
        # Source directly in the current shell context
        if source "$VENV_PATH/bin/activate"; then
            print_success "Virtual environment activated: $VIRTUAL_ENV"
            VENV_ACTIVATED=true
            return 0
        else
            print_error "Failed to activate virtual environment."
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
    else
        print_warning "ultralytics module not found"
        
        if ! run_command_log_error "Installing ultralytics" pip install ultralytics; then 
            return 1
        fi
    fi
    return 0
}

download_model() {
    print_step "Downloading Model File (.pt)"

    if ! mkdir -p "$MODELS_DIR"; then
        print_error "Failed to create directory: $MODELS_DIR"
        return 1
    fi
    
    if [ -f "$PT_MODEL" ]; then
        print_success "Model file already exists: %s" "$PT_MODEL"
        PT_DOWNLOADED=true
    else
        print_info "Downloading YOLOv11n pre-trained model..."
        
        # Navigate to models dir to ensure download lands in correct folder
        pushd "$MODELS_DIR" > /dev/null
        
        # If the file doesn't exist locally, YOLO(...) will trigger a download
        if run_command_log_error "Downloading model $MODEL_NAME.pt" \
            python -c "from ultralytics import YOLO; YOLO('$MODEL_NAME.pt')"; then
            
            if [ -f "$MODEL_NAME.pt" ]; then
                PT_DOWNLOADED=true
                print_success "Model downloaded to $(pwd)/$MODEL_NAME.pt"
            else
                print_error "Download command ran, but file %s not found." "$MODEL_NAME.pt"
                popd > /dev/null
                return 1
            fi
        else
            popd > /dev/null
            return 1
        fi
        
        popd > /dev/null
    fi
    return 0
}

convert_to_onnx() {
    print_step "Converting Model to ONNX Format"

    if [ -f "$ONNX_MODEL" ]; then
        print_success "ONNX model already exists: %s" "$ONNX_MODEL"
        ONNX_CONVERTED=true
    elif [ "$PT_DOWNLOADED" = true ]; then
        # Exporting ONNX (inputs .pt from full path, outputs .onnx to same dir)
        if run_command_log_error "Converting $MODEL_NAME.pt to ONNX" \
            python -c "from ultralytics import YOLO; YOLO('$PT_MODEL').export(format='onnx', opset=17, imgsz=640)"; then
            
            if [ -f "$ONNX_MODEL" ]; then
                ONNX_CONVERTED=true
            else
                print_error "ONNX conversion succeeded, but file not found at expected path."
                return 1
            fi
        else
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
        # Try to find trtexec in path if not at default location
        if [ ! -f "$TRTEXEC_PATH" ]; then
            if command -v trtexec >/dev/null 2>&1; then
                TRTEXEC_PATH=$(command -v trtexec)
            else
                print_error "TensorRT executable not found."
                printf "  Please ensure NVIDIA JetPack SDK is installed.\n"
                return 1
            fi
        fi
        
        if run_command_log_error "Converting $MODEL_NAME.onnx to TensorRT Engine" \
            "$TRTEXEC_PATH" --onnx="$ONNX_MODEL" --fp16 --saveEngine="$ENGINE_MODEL"; then
            
            if [ -f "$ENGINE_MODEL" ]; then
                ENGINE_CONVERTED=true
            else
                print_error "Engine conversion succeeded, but file not found at expected path."
                return 1
            fi
        else
            return 1
        fi
    else
        print_warning "Skipping Engine conversion because the ONNX file does not exist."
    fi
    return 0
}

cleanup_venv() {
    if [ "$VENV_ACTIVATED" = true ]; then
        print_info "Deactivating virtual environment..."
        deactivate
        VENV_ACTIVATED=false
    fi
}

print_summary() {
    print_header "Setup Summary"

    if [ "$LOG_ENABLED" = true ]; then
        printf "  ${BULLET_SYMBOL} Log file: ${CYAN}%s${NC}\n\n" "$LOG_FILE"
    else
        printf "  ${BULLET_SYMBOL} Log file: ${CYAN}Disabled (Use -l to enable)${NC}\n\n"
    fi
    
    printf "\n  --- Model Status ---\n"
    if [ "$PT_DOWNLOADED" = true ]; then
        printf "  ${GREEN}[O]${NC} YOLOv11n (.pt): ${CYAN}%s${NC}\n" "$PT_MODEL"
    else
        printf "  ${RED}[X]${NC} YOLOv11n (.pt)\n"
    fi
    
    if [ "$ONNX_CONVERTED" = true ]; then
        printf "  ${GREEN}[O]${NC} ONNX Model: ${CYAN}%s${NC}\n" "$ONNX_MODEL"
    else
        printf "  ${RED}[X]${NC} ONNX Model\n"
    fi
    
    if [ "$ENGINE_CONVERTED" = true ]; then
        printf "  ${GREEN}[O]${NC} TensorRT Engine: ${CYAN}%s${NC}\n" "$ENGINE_MODEL"
    else
        printf "  ${RED}[X]${NC} TensorRT Engine\n"
    fi
}

# --- Main Execution ---

main() {
    trap cleanup_venv EXIT

    if [ "$LOG_ENABLED" = true ]; then
        # Initialize log file
        > "$LOG_FILE"
        printf "${CYAN}Output from verbose commands is being logged to: ${BOLD}%s${NC}\n" "$LOG_FILE"
    else
        printf "${CYAN}Output from verbose commands is being suppressed (using /dev/null). Use -l/--log for logging.${NC}\n"
    fi

    print_banner

    # Step 1: Check and Activate Venv
    if ! check_and_activate_venv; then
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
}

# --- Script Initialization and Execution ---

parse_arguments "$@"
init_terminal
main