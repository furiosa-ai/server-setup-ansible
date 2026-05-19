# server-setup-ansible

Ansible 기반 멀티노드 Furiosa SDK 자동 배포 자동화 플레이북 모음입니다.
컨트롤 노드 1대에서 다수의 워커 노드에 SSH로 접속하여 SDK 설치부터 Docker 이미지 배포까지 전 과정을 자동화합니다.

---

## 구성 요소

| 구성 요소 | 역할 |
|---|---|
| 컨트롤 노드 | Ansible 설치됨. Playbook 실행 주체. SSH 키 보유 |
| 워커 노드 | Ansible 설치 불필요. SSH + Python3만 있으면 됨 |
| 통신 방식 | 컨트롤 노드 → SSH → 워커 노드 |

![Ansible 노드 구조](docs/ansible_node_structures.png)

---

## 디렉토리 구조

```
.
├── images/                          # 배포할 Docker 이미지 tar.gz 파일 위치
├── playbooks/
│   ├── 01_apt_setup.yml             # Furiosa APT 저장소 설정
│   ├── 02_sdk_apt.yml               # Furiosa SDK APT 패키지 설치 + firmware 업데이트
│   ├── 03_pip_install.yml           # furiosa-llm PIP 패키지 설치 (Ubuntu 22.04/24.04 자동 분기)
│   ├── 04_docker_deploy.yml         # Docker 설치 및 이미지 배포
│   └── 05_host_info.yml             # 워커 노드 시스템 정보 수집
└── scripts/
    └── host_info.sh                 # 워커 노드 정보 수집 스크립트
```

---

## 사전 준비

### 1. 컨트롤 노드에 Ansible 설치

```bash
sudo apt update
sudo apt install -y python3 python3-pip python3-dev
sudo pip3 install ansible
ansible --version
```

### 2. SSH 키 생성 및 워커 노드 배포

```bash
ssh-keygen -t rsa -b 4096
ssh-copy-id <워커노드_USER_ID_1>@<워커노드_IP_1>
ssh-copy-id <워커노드_USER_ID_2>@<워커노드_IP_2>
ssh-copy-id <워커노드_USER_ID_3>@<워커노드_IP_3>
```

### 3. Ansible 인벤토리 설정

`/etc/ansible/hosts` 파일을 생성하고 `/etc/ansible/hosts` 에 워커 노드 목록을 등록합니다.

```ini
[furiosa_workers]
worker1 ansible_host=<워커노드_IP_1> ansible_user=<워커노드_USER_ID_1>
worker2 ansible_host=<워커노드_IP_2> ansible_user=<워커노드_USER_ID_2>
worker3 ansible_host=<워커노드_IP_3> ansible_user=<워커노드_USER_ID_3>


# Examples
[furiosa_workers]
worker1 ansible_host=192.168.1.101 ansible_user=furiosa
worker2 ansible_host=192.168.1.102 ansible_user=furiosa
worker3 ansible_host=192.168.1.103 ansible_user=furiosa
```

연결 테스트:

```bash
ansible furiosa_workers -m ping
```

---

## 실행 순서

```bash
# Step 1: APT 저장소 설정
ansible-playbook playbooks/01_apt_setup.yml --ask-become-pass

# Step 2: SDK APT 패키지 설치 (firmware 업데이트 포함, 수 분 소요)
ansible-playbook playbooks/02_sdk_apt.yml --ask-become-pass

# Step 3: furiosa-llm PIP 패키지 설치
ansible-playbook playbooks/03_pip_install.yml --ask-become-pass

# Step 4: Docker 설치 및 이미지 배포
ansible-playbook playbooks/04_docker_deploy.yml --ask-become-pass

# Step 5: 워커 노드 시스템 정보 수집
ansible-playbook playbooks/05_host_info.yml --ask-become-pass
```

### 특정 노드만 실행

```bash
ansible-playbook playbooks/02_sdk_apt.yml --limit worker1
ansible-playbook playbooks/02_sdk_apt.yml --limit 'worker1,worker2'
```

---

## Playbook 상세

### 01_apt_setup.yml — Furiosa APT 저장소 설정
- `curl`, `gnupg` 설치
- Google Cloud APT 키 등록
- Furiosa APT 저장소 등록 및 `apt update`

### 02_sdk_apt.yml — SDK 패키지 설치
- `furiosa-driver-rngd`, `furiosa-smi`, `furiosa-toolkit-rngd` 설치
- `furiosa-firmware-image-rngd` 설치 및 firmware 업데이트 (비동기, 최대 30분)
- firmware 업데이트 로그를 컨트롤 노드 `~/logs/` 로 수집
- 업데이트 완료 후 워커 노드 자동 종료

> ⚠️ firmware 업데이트 진행 상황은 워커 노드에 별도 터미널로 SSH 접속 후 확인할 수 있습니다.
> ```bash
> tail -f /var/log/furiosa_firmware_update.log
> ```
> 모든 NPU에서 `Success` 가 출력되는지 반드시 확인하세요.

### 03_pip_install.yml — furiosa-llm 설치
Ubuntu 버전에 따라 자동 분기됩니다.

| Ubuntu | 설치 방식 |
|---|---|
| 22.04 | `pip install --user` |
| 24.04 | Python venv (`~/venv`) 생성 후 설치 |

공통 설치 패키지: `furiosa-llm`, `urllib3<2`, `more-itertools<11.0`  
공통 제거 패키지: `torchvision`

### 04_docker_deploy.yml — Docker 이미지 배포
- Docker 미설치 시 자동 설치 (GPG 키, APT 저장소, `docker-ce` 등)
- 컨트롤 노드의 `images/` 디렉토리에서 이미지 파일을 워커 노드 `/tmp/` 로 전송
- `docker load` 후 전송 파일 자동 삭제
- 배포 이미지: `furiosa_validation_tool-offline_2026_1_0_v2_logging.tar.gz`

### 05_host_info.yml — 워커 노드 시스템 정보 수집
- `bc` 패키지 미설치 시 자동 설치
- `scripts/host_info.sh`를 워커 노드로 전송 후 실행
- 수집 항목: OS, 시리얼 번호, BIOS/BMC 버전, CPU/메모리, NPU PCIe 링크 및 전력, 스토리지
- 생성된 로그 파일(`<시리얼번호>_<타임스탬프>.log`)을 컨트롤 노드 `~/logs/`로 수집
- 실행 후 워커 노드의 임시 파일 자동 정리

---

## 실행 결과 상태

| 상태 | 의미 |
|---|---|
| `ok` | 이미 적용되어 있어 변경 없음 (멱등성) |
| `changed` | 변경 사항이 적용됨 |
| `failed` | 오류 발생 — 로그 확인 필요 |
| `skipped` | 조건(`when`)에 맞지 않아 건너뜀 |

---

## 트러블슈팅

| 문제 | 해결 방법 |
|---|---|
| SSH 연결 실패 | `ssh-copy-id` 재실행, 워커 노드 방화벽(`ufw`) 확인 |
| UNREACHABLE 오류 | `hosts` 파일의 IP/user 확인, ping 테스트 |
| apt 패키지 없음 | `01_apt_setup.yml` 먼저 실행 여부 확인 |
| pip 권한 오류 (24.04) | venv 경로 및 소유자 확인 |
| docker load 실패 | 이미지 파일 경로, 용량, 형식(`.tar.gz`) 확인 |
| firmware Success 미출력 | NPU 하드웨어 연결 상태 및 드라이버 재설치 확인 |
