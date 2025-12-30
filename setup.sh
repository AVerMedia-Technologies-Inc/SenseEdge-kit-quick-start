#!/bin/bash

#===============================================================================
#
#                     DEVELOPMENT ENVIRONMENT SETUP SCRIPT
#                       for AVerMedia SenseEdge-kit-quick-start
#
#===============================================================================
#
# Description: Automated setup script for AVerMedia SenseEdge-kit-quick-start
#              development environment.
#
# Prerequisites:
#   - Jetson-based AVerMedia device with JetPack 6.x
#   - Internet connectivity
#   - Correct system time
#   - User must have sudo privileges for 'apt install'
#
# Usage:
#   ./setup.sh 
#
# Options:
#   -h, --help       Show this help message
#   --no-color       Disable colored output
#   -l, --log        Enable logging for pip/apt commands to setup_[timestamp].log
#
#===============================================================================

set -e

# --- Configuration ---
readonly VENV_NAME="realsense_env"
readonly VENV_SUB_DIR="avermedia"
readonly PYCUDA_VERSION="2025.1.2" 
readonly OPENCV_VERSION="4.10.0.84"

# Path to the separate model download/conversion script
readonly MODEL_SCRIPT_PATH="./scripts/download_model.sh"

# Global configuration
USE_COLORS=true
LOG_PIP_COMMANDS=false 
LOG_FILE="./setup_$(date +%Y%m%d_%H%M%S).log"
readonly DEV_NULL="/dev/null"

# Global Variables (Derived from current user's $HOME)
VENV_PATH="$HOME/$VENV_SUB_DIR/$VENV_NAME"

# Step variables
CURRENT_STEP=0
TOTAL_STEPS=7

# Status flags
INTERNET_CONNECTED=false
SYSTEM_TIME_VALID=false
JETPACK_VERSION_CHECKED=false
VENV_CREATED=false
PYCUDA_INSTALLED=false
REALSENSE_INSTALLED=false
OPENCV_INSTALLED=false

#===============================================================================
# Utility Functions
#===============================================================================

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
    # Check for NO_COLOR environment variable safely using expansion :-
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
        # Use $'...' format so variables hold the actual Escape character, 
        # ensuring they work even when passed as arguments to printf %s.
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
    if [ "$TERMINAL_WIDTH" -ge 60 ]; then
        local banner="\n"
        banner+="${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
        banner+="               ${BOLD}${WHITE}DEVELOPMENT ENVIRONMENT SETUP${NC}\n"
        banner+="                 ${WHITE}for SenseEdge-kit-quick-start${NC}\n"
        banner+="${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
        printf "$banner"
    else
        local banner="\n"
        banner+="${BOLD}${WHITE}=== SETUP: SenseEdge-kit-quick-start ===${NC}\n"
        banner+="\n"
        printf "$banner"
    fi
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

print_error() {
    local format="$1"
    shift
    local text=$(printf "$format" "$@")
    printf "${RED}${ERROR_SYMBOL}${NC} %s\n" "$text"
}

print_warning() {
    local format="$1"
    shift
    local text=$(printf "$format" "$@")
    printf "${YELLOW}${WARNING_SYMBOL}${NC} %s\n" "$text"
}

print_info() {
    local format="$1"
    shift
    local text=$(printf "$format" "$@")
    printf "${CYAN}${INFO_SYMBOL}${NC} %s\n" "$text"
}

ask_user() {
    local question="$1"
    local default="$2"
    local response

    while true; do
        printf "${YELLOW}%s${NC}\n" "$question"

        if [ -n "$default" ]; then
            printf "  ${YELLOW}Default: %s${NC}\n" "$default"
            read -p "  Your choice [y/n]: " response
            response=${response:-$default}
        else
            read -p "  Your choice [y/n]: " response
        fi

        case $response in
            [Yy]|[Yy][Ee][Ss]) return 0 ;;
            [Nn]|[Nn][Oo]) return 1 ;;
            *) printf "  ${RED}Please answer yes (y) or no (n).${NC}\n\n" ;;
        esac
    done
}

show_help() {
    cat << EOF
AVerMedia SenseEdge-kit-quick-start Development Environment Setup Script

USAGE:
    ./setup.sh [OPTIONS]

OPTIONS:
    -h, --help      Show this help message and exit
    --no-color      Disable colored output
    -l, --log       Enable logging for apt/pip commands to setup_[timestamp].log (Default: Disabled)

DESCRIPTION:
    This script automates the setup of AVerMedia SenseEdge-kit-quick-start
    development environment. The script will prompt for a password only during 
    system dependency installation (apt install).

    ${BULLET_SYMBOL} Install GPU system dependencies (CUDA, TensorRT, etc.).
    ${BULLET_SYMBOL} Install necessary system packages (python3-pip, python3-venv).
    ${BULLET_SYMBOL} Create a Python virtual environment: ~/avermedia/realsense_env
    ${BULLET_SYMBOL} Install required Python libraries: pycuda, pyrealsense2, opencv-python.

PREREQUISITES:
    ${BULLET_SYMBOL} Jetson-based AVerMedia device (Recommended: JetPack 6.x)
    ${BULLET_SYMBOL} Internet connectivity
    ${BULLET_SYMBOL} Correct system time
    ${BULLET_SYMBOL} Current user must have sudo privileges

EXAMPLES:
    # Interactive setup (Recommended, no logs)
    ./setup.sh
    
    # Interactive setup with detailed logs for pip/apt operations
    ./setup.sh -l

EOF
}

get_log_target() {
    if [ "$LOG_PIP_COMMANDS" = true ]; then
        echo "$LOG_FILE"
    else
        echo "$DEV_NULL"
    fi
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
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
                LOG_PIP_COMMANDS=true
                shift
                ;;
            *)
                init_terminal
                printf "${RED}Unknown option: %s${NC}\n" "$1"
                printf "Use --help for usage information.\n"
                exit 1
                ;;
        esac
    done
}

#===============================================================================
# Core Functions
#===============================================================================

run_command_log_error() {
    local description="$1"
    shift
    local command_to_run=("$@") 
    local log_target=$(get_log_target)

    print_info "%s..." "$description"

    if ! eval "${command_to_run[@]}" >> "$log_target" 2>&1; then
        print_error "%s FAILED." "$description"
        if [ "$LOG_PIP_COMMANDS" = true ]; then
            print_error "Check %s for details." "$LOG_FILE"
        fi
        return 1
    fi

    print_success "%s completed." "$description"
    return 0
}

check_internet() {
    print_info "Checking internet connectivity"
    if command -v wget >/dev/null 2>&1; then
        if wget -q --spider --no-check-certificate --timeout=10 --tries=1 "https://www.avermedia.com" 2>/dev/null; then
            print_success "Internet connectivity confirmed"
            INTERNET_CONNECTED=true
            return 0
        fi
    fi
    print_error "No internet connectivity detected"
    return 1
}

# Helper function to get internet time
get_internet_time() {
    # Extract Date header from a reliable server (Google)
    local remote_date=$(wget -qSO- --max-redirect=0 google.com 2>&1 | grep "^  Date: " | cut -d' ' -f5-10)
    if [ -n "$remote_date" ]; then
        date -d "$remote_date" +%s
    else
        echo "0"
    fi
}

# Enhanced time check function with auto-sync capability
check_time() {
    print_info "Checking system time..."

    local internet_time=$(get_internet_time)
    local current_time=$(date +%s)

    # 1. Fallback: If internet time cannot be fetched (but internet check passed previously)
    if [ "$internet_time" -eq 0 ]; then
        print_warning "Could not fetch precise internet time. Performing basic sanity check."
        # Basic check: Ensure time is at least after Jan 1, 2025
        local min_time=$(date -d "2025-01-01 00:00:00" +%s)
        if [ "$current_time" -lt "$min_time" ]; then
            print_error "System time is critically outdated ($(date))."
            print_info "Please set time manually using: sudo date -s 'YYYY-MM-DD HH:MM:SS'"
            return 1
        fi
        SYSTEM_TIME_VALID=true
        return 0
    fi

    # 2. Precision Check: Compare system time with internet time
    local diff=$(( internet_time - current_time ))
    local abs_diff=${diff#-} # Absolute value

    # Allow a tolerance of 300 seconds (5 minutes)
    if [ "$abs_diff" -gt 300 ]; then
        print_warning "System time is incorrect! Offset by approx $abs_diff seconds."
        print_info "System time:   $(date)"
        print_info "Internet time: $(date -d "@$internet_time")"

        # 3. Ask user to update
        if ask_user "Would you like to update the system time to match internet time?" "y"; then
            print_info "Updating system time (requires sudo)..."
            if sudo date -s "@$internet_time"; then
                print_success "System time updated successfully."
                SYSTEM_TIME_VALID=true
                return 0
            else
                print_error "Failed to update time. Please check your sudo password."
                return 1
            fi
        else
            print_warning "Proceeding with incorrect system time. This may cause SSL/TLS errors during download."
            # We don't fail here, but we warn heavily
            return 0
        fi
    else
        print_success "System time is accurate (within 5 minutes)."
        SYSTEM_TIME_VALID=true
        return 0
    fi
}

check_jetpack_version() {
    print_info "Checking L4T/JetPack version"
    local l4t_release
    if ! l4t_release=$(head -n 1 /etc/nv_tegra_release | cut -f 2 -d ' ' | grep -Po '(?<=R)\d+'); then
        print_error "Failed to determine L4T version. This is likely not a Jetson device."
        return 1
    fi
    
    local revision=$(head -n 1 /etc/nv_tegra_release | cut -f 2 -d ',' | grep -Po '(?<=REVISION: )[0-9.]+')
    local version="$l4t_release.$revision"
    
    print_info "Detected L4T version: R$version"
    
    if [ "$l4t_release" -lt 36 ]; then
        print_warning "Detected L4T version (R$version) is older than R36 (JetPack 6)."
        print_warning "The pycuda installation is intended for JetPack 6 (R36.x)."
        print_warning "Installation might fail. Proceeding with caution."
    fi
    
    JETPACK_VERSION_CHECKED=true
    return 0
}

check_venv_status() {
    print_info "Checking for virtual environment at %s" "$VENV_PATH"
    if [ -d "$VENV_PATH" ]; then
        print_success "Virtual environment already exists."
        
        if ask_user "Do you want to re-CREATE the virtual environment (This will DELETE the existing one)?" "n"; then
            print_warning "Deleting existing VENV: %s" "$VENV_PATH"
            rm -rf "$VENV_PATH"
            VENV_CREATED=false
            return 0
        else
            VENV_CREATED=true
            print_info "Using existing virtual environment. Will proceed to package check/installation."
            return 0
        fi
    fi
    VENV_CREATED=false
    return 0
}

configure_cuda_env() {
    local CUDA_ROOT="/usr/local/cuda"
    local BASHRC_FILE="$HOME/.bashrc"
    local START_TAG="# --- Start AVerMedia CUDA Environment Setup (Global) ---"
    local END_TAG="# --- End AVerMedia CUDA Environment Setup (Global) ---"

    if [ ! -d "$CUDA_ROOT/bin" ]; then
        print_error "CUDA directory not found at $CUDA_ROOT. Environment setup skipped."
        return 1
    fi

    # 1. Export variables for the CURRENT script session (Memory only).
    export CUDA_HOME="$CUDA_ROOT"
    export PATH="$CUDA_ROOT/bin:$PATH"
    export LD_LIBRARY_PATH="$CUDA_ROOT/lib64:$LD_LIBRARY_PATH"
    export CPATH="$CUDA_ROOT/include:$CPATH"
    
    # 2. Persist to .bashrc (File modification).
    if grep -qF "$START_TAG" "$BASHRC_FILE"; then
        print_success "CUDA environment variables already found in ~/.bashrc. Skipping file modification."
    else
        print_info "Appending CUDA environment variables to ~/.bashrc..."
        local CUDA_SETTINGS="
$START_TAG
export CUDA_HOME=\"$CUDA_ROOT\"
export PATH=\"\$CUDA_HOME/bin:\$PATH\"
export LD_LIBRARY_PATH=\"\$CUDA_ROOT/lib64:\$LD_LIBRARY_PATH\"
export CPATH=\"\$CUDA_ROOT/include:\$CPATH\"
$END_TAG
"
        echo "$CUDA_SETTINGS" >> "$BASHRC_FILE"
        print_success "CUDA environment added to ~/.bashrc."
    fi

    return 0
}

install_gpu_system_deps() {
    # List of required system packages for JetPack 6 GPU support
    local packages=("cuda-compiler-12-6" "cuda-profiler-api-12-6" "libcurand-12-6" "libcurand-dev-12-6" "tensorrt" "tensorrt-libs" "python3-libnvinfer" "python3-libnvinfer-dev" "nvidia-l4t-dla-compiler" "libcudla-12-6")
    local missing_packages=()

    print_info "Checking GPU system dependencies..."

    for pkg in "${packages[@]}"; do
        if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed"; then
            missing_packages+=("$pkg")
        fi
    done

    if [ ${#missing_packages[@]} -eq 0 ]; then
        print_success "All GPU system dependencies are already installed."
    else
        print_warning "Missing packages: ${missing_packages[*]}"
        local install_list="${missing_packages[*]}"
        if run_command_log_error "Installing missing GPU dependencies" \
            "sudo apt update && sudo apt install -y $install_list"; then
            
            # Explicitly refresh shared library cache to ensure newly installed libs (like libcudla) are found
            run_command_log_error "Refreshing shared library cache" "sudo ldconfig"
            
            print_success "Missing packages installed successfully."
        else
            return 1 
        fi
    fi

    # Ensure environment variables are set for the current run and .bashrc
    if ! configure_cuda_env; then
        print_warning "Failed to configure CUDA environment variables."
        return 1
    fi

    return 0
}

install_system_deps() {
    local packages=("python3-pip" "python3-venv")
    local missing_packages=()

    print_info "Checking system Python tools (pip, venv)..."

    for pkg in "${packages[@]}"; do
        if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed"; then
            missing_packages+=("$pkg")
        fi
    done

    if [ ${#missing_packages[@]} -eq 0 ]; then
        print_success "System Python tools (pip, venv) are already installed."
        return 0
    else
        print_warning "Missing system packages: ${missing_packages[*]}"
        local install_list="${missing_packages[*]}"
        if run_command_log_error "Installing python3-pip and python3-venv" \
            "sudo apt update && sudo apt install -y $install_list"; then
            print_success "System Python tools installed successfully."
            return 0
        else
            print_error "Failed to install system Python tools."
            return 1 
        fi
    fi
}

create_and_activate_venv() {
    local log_target=$(get_log_target)
    run_command_log_error "Creating Python virtual environment at $VENV_PATH" \
        python3 -m venv "$VENV_PATH" --system-site-packages
    
    if [ $? -ne 0 ]; then return 1; fi
    
    VENV_CREATED=true
    
    # Activate the newly created VENV
    if ! source "$VENV_PATH/bin/activate"; then
        print_error "Failed to activate the newly created VENV."
        return 1
    fi

    print_success "New virtual environment successfully activated."

    local pip_command="$VENV_PATH/bin/pip"
    
    run_command_log_error "Upgrading pip, setuptools, and wheel in VENV" \
        "$pip_command" install --upgrade pip setuptools wheel
        
    return $?
}

check_installed_package() {
    local package_name="$1"
    local required_version="$2"
    local log_target=$(get_log_target)
    
    if [ ! -f "$VENV_PATH/bin/activate" ]; then
        return 1
    fi

    local pip_command="$VENV_PATH/bin/pip"
    local installed_version
    
    installed_version=$("$pip_command" show "$package_name" 2>>"$log_target" | grep -i Version | awk '{print $2}')

    if [ -z "$installed_version" ]; then
        print_warning "$package_name is not installed in the VENV."
        return 1
    fi
    
    if [ -z "$required_version" ] || [ "$installed_version" == "$required_version" ]; then
        print_success "%s (Version %s) is already installed. Skipping installation." "$package_name" "$installed_version"
        return 0 
    else
        print_warning "$package_name is installed (Version %s) but required version is %s." "$installed_version" "$required_version"
        print_warning "The script will attempt to upgrade/install the required version."
        return 1
    fi
}

install_pycuda() {
    if check_installed_package pycuda "$PYCUDA_VERSION"; then
        PYCUDA_INSTALLED=true
        return 0
    fi
    
    print_info "Installing pycuda $PYCUDA_VERSION"
    
    # PyCUDA compilation relies on the CUDA environment variables set in Step 2.
    if run_command_log_error "Downloading and installing pycuda $PYCUDA_VERSION" \
        "$VENV_PATH/bin/pip" install "pycuda==$PYCUDA_VERSION" --no-cache-dir; then
        
        PYCUDA_INSTALLED=true
        return 0
    else
        return 1
    fi
}

install_pyrealsense() {
    if check_installed_package pyrealsense2 ""; then
        REALSENSE_INSTALLED=true
        return 0
    fi
    
    print_info "Installing pyrealsense2"
    
    if run_command_log_error "Installing pyrealsense2" \
        "$VENV_PATH/bin/pip" install pyrealsense2 --no-cache-dir; then
        
        REALSENSE_INSTALLED=true
        return 0
    else
        return 1
    fi
}

install_opencv() {
    if check_installed_package opencv-python "$OPENCV_VERSION"; then
        OPENCV_INSTALLED=true
        return 0
    fi
    
    print_info "Installing opencv-python $OPENCV_VERSION"
    
    if run_command_log_error "Installing opencv-python $OPENCV_VERSION" \
        "$VENV_PATH/bin/pip" install "opencv-python==$OPENCV_VERSION" --no-cache-dir; then
        
        OPENCV_INSTALLED=true
        return 0
    else
        return 1
    fi
}

execute_model_script() {
    if [ ! -f "$MODEL_SCRIPT_PATH" ]; then
        print_warning "Model download/conversion script not found at ${BOLD}%s${NC}. Skipping model related steps." "$MODEL_SCRIPT_PATH"
        return 0
    fi
    
    if ask_user "Do you want to run the model download and conversion script (${BOLD}$MODEL_SCRIPT_PATH${NC})?" "y"; then
        
        print_info "Executing external model script: %s" "$MODEL_SCRIPT_PATH"
        
        # Pass -l argument if logging is enabled in setup.sh
        local script_args=""
        if [ "$LOG_PIP_COMMANDS" = true ]; then
            script_args="-l"
        fi
        
        # Use simple execution, assuming the script handles its own logging flags correctly now
        if ! /bin/bash "$MODEL_SCRIPT_PATH" $script_args; then
            print_error "Model script (%s) failed to execute or completed with errors. See its output/log for details." "$MODEL_SCRIPT_PATH"
            return 1
        fi
        
        print_success "Model script (%s) completed successfully." "$MODEL_SCRIPT_PATH"
        return 0
    else
        print_info "Skipping model download/conversion as requested."
        return 0
    fi
}

print_summary() {
    print_header "Setup Summary"

    if [ "$LOG_PIP_COMMANDS" = true ]; then
        printf "  ${BULLET_SYMBOL} Log file: ${CYAN}%s${NC}\n\n" "$LOG_FILE"
    else
        printf "  ${BULLET_SYMBOL} Log file: ${CYAN}Disabled (Re-run with -l/--log to enable)${NC}\n\n"
    fi

    if [ "$INTERNET_CONNECTED" = true ]; then
        printf "  ${GREEN}[O]${NC} Internet connectivity verified\n"
    else
        printf "  ${RED}[X]${NC} Internet connectivity verified\n"
    fi
    
    if [ "$VENV_CREATED" = true ]; then
        printf "  ${GREEN}[O]${NC} Virtual environment created/re-used: ${CYAN}%s${NC}\n" "$VENV_PATH"
    else
        printf "  ${RED}[X]${NC} Virtual environment created\n"
    fi
    
    printf "\n  --- Python Packages in VENV ---\n"
    if [ "$PYCUDA_INSTALLED" = true ]; then
        printf "  ${GREEN}[O]${NC} pycuda (%s) installed\n" "$PYCUDA_VERSION"
    else
        printf "  ${RED}[X]${NC} pycuda installed\n"
    fi
    
    if [ "$REALSENSE_INSTALLED" = true ]; then
        printf "  ${GREEN}[O]${NC} pyrealsense2 installed\n"
    else
        printf "  ${RED}[X]${NC} pyrealsense2 installed\n"
    fi
    
    if [ "$OPENCV_INSTALLED" = true ]; then
        printf "  ${GREEN}[O]${NC} opencv-python (%s) installed\n" "$OPENCV_VERSION"
    else
        printf "  ${RED}[X]${NC} opencv-python installed\n"
    fi
}

#===============================================================================
# Script Initialization and Main Process
#===============================================================================

parse_arguments "$@"
init_terminal

if [ "$EUID" -eq 0 ]; then
    print_warning "Warning: The script is currently running as 'root' (via sudo). All VENV operations will be owned by root, which is NOT recommended."
    print_warning "Please consider running the script without 'sudo' as recommended in the usage, allowing 'sudo' to prompt only for 'apt install'."
    print_error "Aborting to prevent potential VENV permission issues."
    exit 1
fi

if [ "$LOG_PIP_COMMANDS" = true ]; then
    > "$LOG_FILE"
    printf "${CYAN}Output from apt/pip commands is being logged to: ${BOLD}%s${NC}\n" "$LOG_FILE"
else
    printf "${CYAN}Output from apt/pip commands is being suppressed (using /dev/null). Use -l/--log for logging.${NC}\n"
fi

print_banner
printf "${CYAN}Target VENV path is: ${BOLD}%s${NC}\n" "$VENV_PATH"
printf "\n"

# --- Step 1: Check Prerequisites ---
print_step "Checking Prerequisites"
check_jetpack_version
if ! check_internet; then exit 1; fi
if ! check_time; then exit 1; fi
if ! check_venv_status; then exit 1; fi

# --- Step 2: Install GPU System Dependencies (CUDA, Profiler, CURAND, TRT) ---
print_step "Installing GPU System Dependencies"
if ! install_gpu_system_deps; then
    print_error "GPU system dependency installation failed."
    exit 1
fi

# --- Step 3: Install System Dependencies (Python tools) ---
print_step "Installing System Dependencies (Python Tools)"
if ! install_system_deps; then 
    print_error "System dependency installation failed. Please ensure you have sudo privileges and entered the password correctly."
    exit 1
fi

# --- Step 4: Create/Activate/Configure Virtual Environment ---
print_step "Creating/Configuring Virtual Environment"
if [ "$VENV_CREATED" = false ]; then
    # VENV was deleted or does not exist, create and activate
    if ! create_and_activate_venv; then exit 1; fi
else
    # VENV exists and user chose to keep it. Activate and upgrade tools.
    print_info "Activating existing virtual environment..."
    if source "$VENV_PATH/bin/activate"; then
        print_success "Existing virtual environment successfully activated."
        
        # Upgrade tools in the activated environment
        pip_command="$VENV_PATH/bin/pip" 
        run_command_log_error "Upgrading pip, setuptools, and wheel in existing VENV" \
            "$pip_command" install --upgrade pip setuptools wheel
        print_success "Virtual environment is ready for package checks."
    else
        print_error "Failed to activate existing virtual environment."
        exit 1
    fi
fi

# --- Step 5: Install Python Dependencies (PyCUDA) ---
print_step "Installing Python Dependencies (PyCUDA)"
if ! install_pycuda; then exit 1; fi

# --- Step 6: Install Python Dependencies (pyrealsense2) ---
print_step "Installing Python Dependencies (pyrealsense2)"
if ! install_pyrealsense; then exit 1; fi

# --- Step 7: Install Python Dependencies (OpenCV) ---
print_step "Installing Python Dependencies (opencv-python)"
if ! install_opencv; then exit 1; fi

printf "\n${BOLD}${CYAN}--- NEXT: Model Download & Conversion ---${NC}\n"
execute_model_script

printf "\n"
print_header "Setup Complete"
print_summary

printf "\n"
print_header "Next Steps"

printf "  ${BOLD}1. Activate the Environment (Manual):${NC}\n"
printf "     In a new terminal or after logout/login, CUDA environment variables will be set automatically.\n"
printf "     You only need to activate the Python virtual environment:\n"
printf "       ${CYAN}source %s/bin/activate${NC}\n" "$VENV_PATH"
printf "\n"

printf "  ${BOLD}2. Run Your Application:${NC}\n"
printf "     Once the environment is active, you can run your project's main script.\n"
printf "\n"

printf "  ${BOLD}3. Model Conversion:${NC}\n"
printf "     If you skipped the model script, you can run it manually:\n"
printf "       ${CYAN}/bin/bash %s${NC}\n" "$MODEL_SCRIPT_PATH"
printf "\n"

printf "  ${BOLD}4. Check Log File (if issues occur):${NC}\n"
if [ "$LOG_PIP_COMMANDS" = true ]; then
    printf "     ${CYAN}cat %s${NC}\n" "$LOG_FILE"
else
    printf "     (Logging is disabled. Re-run with ${CYAN}-l/--log${NC} to capture output.)\n"
fi
printf "\n"

if [ "$INTERNET_CONNECTED" = false ] || [ "$SYSTEM_TIME_VALID" = false ] || \
    [ "$VENV_CREATED" = false ] || [ "$PYCUDA_INSTALLED" = false ] || \
    [ "$REALSENSE_INSTALLED" = false ] || [ "$OPENCV_INSTALLED" = false ]; then
    print_error "Some necessary steps failed. Please check the setup summary above for details."
    if [ "$LOG_PIP_COMMANDS" = true ]; then
        print_error "Check the log file %s for command output." "$LOG_FILE"
    fi
    exit 1
fi

print_success "SenseEdge-kit-quick-start development environment setup completed successfully!"

exit 0