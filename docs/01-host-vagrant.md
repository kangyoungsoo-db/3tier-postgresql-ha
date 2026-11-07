> 이 문서는 `3tier-rocky10-guide-v16.md` 의 228~340줄을 옮겨 공개용으로 문장을 다듬은 것이다. 코드, 명령, 출력, 설정값은 원본 그대로이고, 비밀번호와 로컬 경로만 자리표시자로 바꿨다.

## 1. 호스트 PC 사전 준비

```bash
vboxmanage --version
vagrant --version
```

**Rocky Linux 10 박스 받기: 알아두어야 할 점**

Vagrant Cloud에 등록된 `rockylinux/10` 박스는 실제 파일을 가리키는 링크가 깨져 있어(버전 `0.0.0`, 다운로드 시 `404`) 그냥 `vagrant up`을 실행하면 실패한다. 아래 2장의 Vagrantfile은 Rocky 공식 미러의 실제 파일 URL을 `config.vm.box_url`로 직접 지정해 이 문제를 우회한다. 시간이 지나 파일명이 바뀌어 다시 404가 나면 https://dl.rockylinux.org/pub/rocky/10/images/x86_64/ 에서 최신 `Rocky-10-Vagrant-Vbox-*.x86_64.vagrant.virtualbox.box` 파일명을 확인해 `box_url` 값만 교체하면 된다.

**CPU 요구사항**: Rocky Linux 10부터 x86-64-v3(AVX2 등) 이상이 필요하다. VM이 부팅 직후 커널 패닉이 나면 이 조건부터 의심한다.

---

## 2. Vagrantfile 작성

**이유**: 3대(web01/was01/db01)를 매번 수동으로 만들지 않고, 이름, IP, 리소스만 바뀌는 반복 구조이므로 Ruby 해시로 정의해 `each`로 반복 생성한다. 관리망은 Vagrant의 `private_network` 기능으로 자동 설정하고, 서비스망용 NIC 2장은 `VBoxManage`로 직접 추가한 뒤 게스트 안에서 수동으로 bond0을 구성한다(자동화 기능이 본딩까지는 지원하지 않기 때문).

```ruby
require 'fileutils'
# -*- mode: ruby -*-
# vi: set ft=ruby :

# 3-Tier 폐쇄망 실습 - Rocky Linux 10
# web01(Presentation) / was01(Application) / db01(Data)

NODES = {
  "web01" => {
    ip_mgmt: "192.168.10.111",
    mem: 2048, cpu: 2,
    extra_disks: []
  },
  "was01" => {
    ip_mgmt: "192.168.10.112",
    mem: 2048, cpu: 2,
    extra_disks: []
  },
  "db01" => {
    ip_mgmt: "192.168.10.113",
    mem: 2560, cpu: 2,
    # pgdata / pgwal / pgbackup 용 추가 디스크 (단위: GB)
    extra_disks: [
      { name: "pgdata",   size: 20 },
      { name: "pgwal",    size: 5 },
      { name: "pgbackup", size: 5 }
    ]
  }
}

Vagrant.configure("2") do |config|
  config.vm.box = "rockylinux/10"
  config.vm.box_url = "https://dl.rockylinux.org/pub/rocky/10.2/images/x86_64/Rocky-10-Vagrant-Vbox-10.2-20260525.0.x86_64.vagrant.virtualbox.box"

  # v16: 부팅 대기 시간. 기본값(300초)이 이 박스(NIC 4장, 첫 부팅)에는 짧아서 `vagrant up`이 매번
  #      "Timed out while waiting for the machine to boot"로 끝났습니다. VM은 실제로 부팅 중인데 Vagrant만 먼저 포기한 것입니다.
  config.vm.boot_timeout = 900
  # v16: 호스트↔게스트 공유 폴더는 쓰지 않습니다(파일은 python http.server/curl로 전달). 마운트 시도 자체를 끕니다.
  config.vm.synced_folder ".", "/vagrant", disabled: true

  NODES.each do |name, spec|
    config.vm.define name do |node|
      node.vm.hostname = name

      # 관리망(192.168.10.0/24) - Vagrant가 자동으로 NIC을 추가하고 IP를 설정 시도
      node.vm.network "private_network", ip: spec[:ip_mgmt]

      node.vm.provider "virtualbox" do |vb|
        vb.name = "3t-r10-#{name}"
        vb.memory = spec[:mem]
        vb.cpus = spec[:cpu]

        # 서비스망용 NIC 2장을 내부 네트워크(intnet) "svc-net"으로 직접 연결
        vb.customize ["modifyvm", :id, "--nic3", "intnet", "--intnet3", "svc-net", "--nictype3", "virtio"]
        vb.customize ["modifyvm", :id, "--nic4", "intnet", "--intnet4", "svc-net", "--nictype4", "virtio"]

        # v16: 게스트 시계 안정화 — 이 줄이 없던 VM은 세 대 모두 clocksource가 acpi_pm이었고, 적용하면 tsc가 됩니다(§5-8, §16-10).
        vb.customize ["modifyvm", :id, "--paravirtprovider", "kvm"]

        # db01 전용 추가 디스크 생성/연결 (pgdata, pgwal, pgbackup)
        spec[:extra_disks].each_with_index do |disk, idx|
          disk_dir = File.join(File.dirname(__FILE__), ".vagrant", "disks")
          FileUtils.mkdir_p(disk_dir) unless File.directory?(disk_dir)
          disk_path = File.join(disk_dir, "#{name}-#{disk[:name]}.vdi")
          unless File.exist?(disk_path)
            vb.customize ["createmedium", "disk", "--filename", disk_path, "--size", disk[:size] * 1024]
          end
          vb.customize ["storageattach", :id,
                         "--storagectl", "SATA Controller",
                         "--port", (1 + idx).to_s,
                         "--device", "0",
                         "--type", "hdd",
                         "--medium", disk_path]
        end
      end
    end
  end
end
```

> ⚠️ **v16: `vagrant up` 타임아웃(`Timed out while waiting for the machine to boot`)**: 위 Vagrantfile의 `config.vm.boot_timeout = 900` 두 줄이 없으면 Vagrant는 300초만 기다리고 포기한다. 이 문서의 이전 버전(v15)에는 이 줄이 없어서 web01, db01, web02, was02 모두에서 재현됐다. 이미 VM을 만든 뒤라면 위 두 줄만 추가하고 `vagrant reload <이름>`으로 반영한다(VM 디스크는 그대로다). 타임아웃이 나도 VM 자체는 떠 있는 경우가 대부분이라 `vagrant ssh <이름>`이 되는지부터 확인한다. 다만 `vagrant up`이 중간에 끝난 VM은 호스트명(`localhost.localdomain`)과 관리망 IP가 자동 설정되지 않았을 수 있다(§3-1, §3-3).

> `--storagectl "SATA Controller"` 이름이 박스마다 다를 수 있다. 오류가 나면 `VBoxManage showvminfo 3t-r10-db01 | grep "Storage Controller Name"`으로 실제 이름을 확인해 바꾼다.

> **v16: `--paravirtprovider kvm` (권장)**: VirtualBox 기본 설정에서는 게스트가 TSC를 `unstable`로 판정해 `acpi_pm`을 시계로 쓰는데, 이 PC에서는 그 상태에서 시계가 초 단위로 튀고 유휴 부하가 컸다(§5-8, §16-10). 위 `vb.customize` 한 줄을 넣고 처음부터 만들면 된다. **이미 만든 VM**에는 꺼진 상태에서 `vagrant halt <이름>` → `VBoxManage modifyvm 3t-r10-<이름> --paravirtprovider kvm` → `vagrant up <이름>`으로 적용한다. 재현 기록에서는 이 `modifyvm` 방식으로 web01, was01, db01에 적용해 세 대 모두 `tsc`가 됐다. 위 Vagrantfile의 `vb.customize` 한 줄 형태로 처음부터 만든 기록은 아직 없어 **미실행**이다.

```bash
vagrant up
vagrant status   # 3대 모두 running인지 확인
```

---

