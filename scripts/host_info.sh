#!/bin/bash

# 0. 의존성 체크 및 루트 권한 확인
if ! command -v bc &> /dev/null; then echo "Error: 'bc' package is required."; exit 1; fi

# 1. 정보 추출 (기존 로직)
HOSTNAME=$(hostname)
OS_PRETTY_NAME=$(grep "PRETTY_NAME=" /etc/os-release | cut -d'=' -f2 | tr -d '"')
SERIAL_NO=$(sudo dmidecode -s system-serial-number 2>/dev/null | xargs || echo "Unknown")
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOG_FILE="${SERIAL_NO}_${TIMESTAMP}.log"

get_bios_ver() { sudo dmidecode -s bios-version 2>/dev/null || echo "Unknown"; }
get_bmc_ver() { sudo ipmitool mc info 2>/dev/null | grep "Firmware Revision" | cut -d':' -f2 | xargs || echo "Unknown"; }

get_npu_info() {
    local dev_list=$(lspci -d 1ed2: | awk '{print $1}')
    [ -z "$dev_list" ] && { echo "    - info: \"No Furiosa NPU detected\""; return; }

    local count=0
    for pci_addr in $dev_list; do
        [[ "$pci_addr" != *:*:*.* ]] && full_pci_addr="0000:$pci_addr" || full_pci_addr="$pci_addr"
        local pci_path="/sys/bus/pci/devices/$full_pci_addr"
        local speed=$(cat "$pci_path/current_link_speed" 2>/dev/null || echo "Unknown")
        local width=$(cat "$pci_path/current_link_width" 2>/dev/null || echo "Unknown")
        
        # Power 정보 (debugfs)
        local mgmt_path="/sys/kernel/debug/rngd/mgmt${count}"
        local pwr_limit="Unknown"
        local pwr_sense_raw="Unknown"

        if [ -d "$mgmt_path" ]; then
            # Power Limit 추출
            local limit_mw=$(sudo cat "$mgmt_path/power_limit_mw" 2>/dev/null)
            [[ -n "$limit_mw" ]] && pwr_limit="$((limit_mw / 1000))W"

            # Power Sense Raw Value 추출 (가공 없이 출력)
            pwr_sense_raw=$(sudo cat "$mgmt_path/power_sense" 2>/dev/null)
        fi

        echo "    - device: \"npu$count ($full_pci_addr)\""
        echo "      pcie_link: \"$speed x$width\""
        echo "      power_limit: \"$pwr_limit\""
        echo "      pwr_sense_raw: \"$pwr_sense_raw\"" # 로우 데이터 출력
        ((count++))
    done
}

get_ssd_info() {
    lsblk -dno NAME,MODEL,SIZE,TRAN | while read -r line; do
        local name=$(echo $line | awk '{print $1}')
        local size=$(echo $line | awk '{print $3}')
        local tran=$(echo $line | awk '{print $4}')
        local model=$(echo $line | awk '{$1=""; $3=""; $4=""; print $0}' | xargs)
        echo "    - name: \"$name\""
        echo "      model: \"${model:-Unknown}\""
        echo "      size: \"$size\""
        echo "      interface: \"${tran:-sata}\""
    done
}

# 2. 결과 생성 함수 (화면 출력 및 파일 저장을 위해 함수화)
generate_report() {
    cat <<EOF
=====================================================
    FURIOSA NPU APPLIANCE SETUP COMPLETION REPORT            
=====================================================
report_generated: "$(date)"
machine_info:
  hostname: "$HOSTNAME"
  os: "$OS_PRETTY_NAME"
  serial_number: "$SERIAL_NO"
  firmware:
    bios_version: "$(get_bios_ver)"
    bmc_version: "$(get_bmc_ver)"
  hardware:
    motherboard: "$(cat /sys/class/dmi/id/board_vendor 2>/dev/null) ($(cat /sys/class/dmi/id/board_name 2>/dev/null))"
    cpu_model: "$(grep -m1 "model name" /proc/cpuinfo | cut -d':' -f2 | xargs)"
    total_cores: $(nproc)
    memory_total: "$(grep "MemTotal" /proc/meminfo | awk '{printf "%.1f GiB", $2/1024/1024}')"
  npu_status:
$(get_npu_info)
  storage:
$(get_ssd_info)
=====================================================
EOF
}

# 3. 실행 및 저장
generate_report | tee "$LOG_FILE"

echo -e "\n[DONE] 리포트가 생성되었습니다: $LOG_FILE"

