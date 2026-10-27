# ugreen-cs201x

UGREEN NASync **DXP2800 GT** のファン／温度センサを標準の Linux **hwmon**、前面の ARGB LED を
標準の **LED クラス**として公開する out-of-tree カーネルモジュールと、
TrueNAS Community Edition 用の導入スクリプト。

> *Out-of-tree hwmon (fans, temperatures) and LED class (front panel ARGB LEDs)
> drivers for the Chipsea CS201x EC found in the UGREEN
> NASync DXP2800 GT, packaged for TrueNAS Community Edition (formerly
> TrueNAS SCALE). Requires Linux 6.11 or later. Derived from UGREEN's GPL
> kernel release. Documentation is in Japanese; the code and its comments are
> in English.*

## これは何か

UGOS Pro をやめて TrueNAS Community Edition（25.04 以降。旧称 TrueNAS SCALE）を入れると、
ファンを制御する主体がいなくなります。
UGREEN が GPL 義務で公開しているカーネルソース
([ugreen-opensource/kernel-6.12](https://github.com/ugreen-opensource/kernel-6.12))
の `drivers/ugreen/ug_201x.c` に DXP2800 GT 用のファンドライバがありますが、

- そのファイルは `drivers/ugreen/Makefile` の `obj-m` に載っておらず（`CONFIG_UG_OSS_REMOVE`
  の区画から Makefile 行だけが削除されている）、そのままではビルドできない
- インタフェースが `/proc/it86/fan` に `set 128` と書く独自テキスト API のみで、
  `sensors` / `fancontrol` / TrueNAS のレポート画面からは一切見えない
- ARGB LED (`leds-sio-201x.c`) と `extern` で相互参照しており単体ビルド不可

そこでファンと温度の部分を切り出して hwmon ABI で公開し直し、LED も移植して LED クラスで
公開し、1 つのモジュールにまとめたのがこのリポジトリです。

## 対象機種

**DXP2800 GT のみ**（DMI の product name が `DXP2800 GT`、Super I/O チップ ID `0x2011`）。

同じ「GT」でもチップが違うので他機種では動きません。参考：

| 機種 | チップ | 状況 |
|---|---|---|
| DXP2800/4800/4800 Plus/6800/8800/480T Plus, DH2600 | ITE IT8613 | **上流の `it87` ドライバで動く**（このリポジトリは不要）|
| iDX6011 / 6012 / 6011 Pro, DXP4800 GT | ITE IT55xx (ACPI EC 0x62/0x66) | 上流に相当ドライバなし。別途移植が必要 |
| **DXP2800 GT** | **Chipsea CS201x** | **ここ** |

## TrueNAS への導入手順（まとめ）

すべて NAS 上で、管理者ユーザー（例: `truenas_admin`）として SSH ログインして行います。
TrueNAS 25.04 以降は `root` での SSH ログインが既定で無効なので、特権が要る操作は `sudo` を付けます。

**事前条件**

- TrueNAS Community Edition 25.04 以降（Linux 6.11 以降）
- データプールが 1 つ以上ある（モジュールをシステム更新で消えない場所に置くため）
- Docker が使える（UI の **Apps** を有効化すると入ります。ビルドをコンテナ内で行うため）

**手順**

スクリプトは `bash` を付けて実行します（ホームディレクトリなどが `noexec` でマウントされていると、
`./scripts/...` の直接実行は `Permission denied` になるためです）。

1. **取得**: リポジトリを clone します。置き場所はどこでも構いません（次の手順でプールへコピーします）。

   ```sh
   git clone https://github.com/hmdkj/ugreen-dxp2800gt-drivers
   cd ugreen-dxp2800gt-drivers
   ```

2. **ビルド**: Docker コンテナ内で `.ko` を作ります。NAS のルート FS には何も入りません。

   ```sh
   sudo bash ./scripts/build-in-docker.sh     # → build/$(uname -r)/ に .ko ができる
   ```

3. **インストール**: ソース・スクリプト・`.ko` をプール上の `/mnt/<pool>/apps/ugreen-cs201x` にコピーします。
   以降はそこにあるものを使います。

   ```sh
   sudo bash ./scripts/install-truenas.sh
   ```

4. **ファンカーブの確認**: `/mnt/<pool>/apps/ugreen-cs201x/contrib/fancontrol.conf.in` を開き、
   `MINSTOP` / `MINSTART` を機体に合わせます（測り方は「ファンカーブの実測」）。

5. **手動で一度実行**して動作を確かめます。

   ```sh
   sudo bash /mnt/<pool>/apps/ugreen-cs201x/scripts/ugreen-init.sh
   ```

   `fancontrol running` と出れば成功です。失敗した場合は同じ場所の `ugreen-init.log` と
   `dmesg` を見てください。

6. **起動時に自動実行**する設定を UI で登録します。

   ```
   System Settings → Advanced → Init/Shutdown Scripts → Add
     Description: ugreen fan and LED control
     Type:        Command
     Command:     /mnt/<pool>/apps/ugreen-cs201x/scripts/ugreen-init.sh
     When:        Post Init
   ```

7. **再起動して確認**します。`ugreen-init.log` に新しい起動の記録があり、`fancontrol` が動いていれば完了です。

**TrueNAS を更新したとき**はカーネルが変わるので、`.ko` の再ビルドが必要です
（「カーネル更新時」を参照）。ビルドや動作がうまくいかない場合は
`scripts/collect-hw-info.sh` で環境を確認できます。

## 公開される hwmon 属性

`/sys/class/hwmon/hwmonN/`（`name` は `ugreen_cs201x`）:

| 属性 | 内容 |
|---|---|
| `fan1_input`, `fan1_label` | CPU ファン回転数 [rpm]（EC が rpm を直接返すので変換なし）|
| `fan2_input`, `fan2_label` | システムファン回転数 [rpm] |
| `fan1_fault`, `fan2_fault` | duty > 0 なのに 0 rpm のとき `1` |
| `pwm1`, `pwm2` | ファン duty、hwmon 標準の **0–255**（EC 側は 0–100 % なので約 2.5 段/％）|
| `pwm1_enable`, `pwm2_enable` | `1` = 手動制御のみ（後述）|
| `temp1_input`, `temp1_label` | CPU NTC [m°C]（EC が線形化済みの ℃ を返すので ×1000）|
| `temp2_input`, `temp2_label` | 基板 NTC [m°C] |

`pwm*_enable` は **`1` しか受け付けません**。CS201x には自動ファン制御モードのレジスタが
存在せず（ベンダコード冒頭の `FAN2_PWM_CTRL_REG` 等は IT8613 ドライバからのコピペ残骸で
未参照）、`FANx_EN` は PWM 出力のゲートでしかありません。`0` を書いたときに全開になるのか
停止するのかが不明なままそれを「hwmon の `pwm_enable=0`（= 制御なし・全開）」に割り当てると
最悪機体を焼くので、`-EOPNOTSUPP` を返します。`fancontrol` はこれを想定した実装
（`pwm_enable=0` が失敗したら `pwm_enable=1` + `pwm=255` にフォールバック）なので、
終了時はファン全開という安全側に倒れます。

### モジュールパラメータ

| パラメータ | 既定 | 説明 |
|---|---|---|
| `force` | `0` | DMI の機種判定を飛ばす（チップ ID の確認は残る）|
| `pwm_readback` | `1` | `pwm*` を EC の duty レジスタから読む。読めない機体では `0` にして「最後に書いた値」を返させる |
| `unload_pwm` | `-1` | アンロード時に両ファンへ書き込む pwm 値。`-1` は EC に触らない |

## ベンダコードとの差分

`ug_201x.c` からレジスタマップとアクセス手順はそのまま引き継ぎ、以下を変えています。

- procfs ではなく hwmon (`devm_hwmon_device_register_with_info`) で公開
- **EC の I/O ウィンドウを `devm_request_region()` で確保**し、`acpi_check_resource_conflict()`
  で ACPI の予約と衝突しないか確認する。ファームウェアが先に予約している場合（DXP2800 GT では
  `pnp 00:03` が 0x200–0x207 を恒久的に持つ）は、警告を出してそのまま使う
  （ベンダ版は `0x2e/0x2f` しか確保せず、しかも `release_region()` した後に EC を叩いている）
- チップ ID に加えて **DMI の product name も照合**（ベンダ版はチップ ID だけを見るので、
  他機種で `0x2e` を叩く余地がある）
- 読み値を `HZ/2` キャッシュ（hwmon は属性 1 個ずつ read されるため、素通しだと
  `sensors` 1 回で EC トランザクションが十数回走る）
- グローバル変数を廃止し、状態は per-device 構造体に閉じ込め
- ベンダの `ug_msleep()` を削除。`CONFIG_UG_FEAT_MSLEEP` が定義されていないと丸ごと
  no-op になる関数で、この config はベンダの Kconfig にも `ug_x86_64_defconfig` にも
  存在しない。つまり**出荷 UGOS でもディレイ 0 で動いている**ため、遅延なしを踏襲した
- `InitEc()` の宣言位置を修正（`-Wdeclaration-after-statement` はカーネルでは常時有効で、
  `CONFIG_WERROR=y` だとビルドエラーになる）
- watchdog / 電源復帰設定（AMD FCH MMIO `0xFED8035B`）は移植していない。ARGB LED は
  `ugreen-cs201x-leds.c` として移植し、同じモジュールにリンクした（次節）

`W=1` で警告ゼロを維持しています。

## 前面 LED（`ugreen-cs201x-leds.c`）

> 実機で、ビルドと LED の点灯を確認済みです。
> 下の「未確認」の項目は、ベンダコードの読み取りからの推測です。

前面の ARGB LED（power / LAN / disk1 / disk2）は、ファンと同じ EC のレジスタ空間にあります。
EC の I/O ウィンドウとロックは `ugreen-cs201x-core.c` が持ち、LED のコードは同じモジュール内から
専用の関数経由でそれを借ります。I/O ポートには直接触れず、
アクセスできる EC アドレスも LED のブロックだけに限られます（ファンのレジスタには届きません）。
そのため、**先に `ugreen-cs201x` をロードしてください**（`ugreen-init.sh` はその順で行います）。

LED は **multicolor LED クラス**として `/sys/class/leds/` に現れます。

| デバイス | 用途 |
|---|---|
| `ugreen:rgb:power` | 電源 |
| `ugreen:rgb:lan` | ネットワーク |
| `ugreen:rgb:disk-1`, `ugreen:rgb:disk-2` | ディスク |

```sh
L=/sys/class/leds/ugreen:rgb:disk-1
echo "255 0 0" > $L/multi_intensity     # 赤（R G B）
echo 255 > $L/brightness                # 点灯
echo 0 > $L/brightness                  # 消灯
```

LED の点灯状態は、ドライバのロード直後は電源のみ点灯、他は消灯です（ベンダドライバと同じ）。
`ugreen-init.sh` は夜に眩しくないよう、電源 LED を **暗い緑の常時点灯**（`multi_intensity` が `0 3 0`）に
設定します。明るさを変えたいときは、スクリプト先頭付近の `POWER_LED_RGB` の緑の値（0〜255）を書き換えてください。

### LAN のアクティビティに連動させる

```sh
modprobe ledtrig-netdev
L=/sys/class/leds/ugreen:rgb:lan
echo netdev > $L/trigger
echo enp1s0 > $L/device_name            # 実際のインタフェース名に置き換える
echo 1 > $L/link; echo 1 > $L/tx; echo 1 > $L/rx
```

### ディスクアクセスに連動させる

点滅が眩しいため、ドライバは **disk LED を消灯のままにします**（`ugreen-init.sh` も何もしません）。
ディスクアクセスに連動させたい場合は、手動で次のように設定します
（再起動すると消灯に戻ります。常時連動させたいなら `ugreen-init.sh` の電源 LED の設定の後に同じ行を足してください）。

```sh
for n in 1 2; do echo disk-activity > /sys/class/leds/ugreen:rgb:disk-$n/trigger; done
```

明るさを落として使う場合は、`multi_intensity` を暗い色にします（例: `echo "0 40 0" > .../multi_intensity`）。

カーネルのトリガーは「どれかのディスクにアクセスがあった」という 1 つの信号なので、
**どのディスクにアクセスしても 2 つの LED が一緒に点滅します**（ディスクごとには光りません）。
常駐プロセスは不要で、負荷はほぼゼロです。対象は libata 経由のディスクで、NVMe は連動しません。
色は LED の `multi_intensity`（既定は白）に従います。

TrueNAS のカーネルでは `ledtrig-netdev` はモジュールで、`ledtrig-blkdev` は含まれていません。
ディスクごとの連動はカーネルのトリガーだけではできず、`disk-activity` は全ディスクの合算になります。

### 未確認

- `0x20005440`（フロー制御）の意味。ベンダコードは probe で 1、remove で 0 を書くが、
  コメントと値が矛盾している。
- 色レジスタと「light」レジスタの関係。このドライバは明るさを RGB に畳み込み、light は 255 固定。
- 点滅の周期とデューティの単位（ms を 50 で割った値と推測）。
- 電源 LED 以外の初期色（ベンダドライバも色を設定しない）。

## ビルド

### TrueNAS Community Edition（推奨）

対象カーネルは Linux 6.11 以降です（`platform_driver` の `.remove` が `void` を返す API を使うため）。
TrueNAS 25.10 は 6.12 LTS なので問題ありません。

TrueNAS のルート FS は読み取り専用かつシステム更新で作り直されるため、
**appliance 上で apt を叩かず、Docker コンテナ内でビルドして `.ko` だけ取り出します**。

```sh
git clone https://github.com/hmdkj/ugreen-dxp2800gt-drivers && cd ugreen-dxp2800gt-drivers
bash ./scripts/build-in-docker.sh          # → build/$(uname -r)/ugreen-cs201x.ko
```

このスクリプトは、ビルドに使うカーネルヘッダを次の優先順位で選びます。

1. **appliance のヘッダ（既定）**: TrueNAS には稼働カーネルのヘッダが
   `/lib/modules/$(uname -r)/build`（→ `/usr/src/linux-headers-*`）として入っています。
   これを `/usr/src` ごとコンテナに読み取り専用で渡し、コピーして使います。
   `Module.symvers` が含まれるので、稼働カーネルと完全に一致するモジュールができます。
   ヘッダは `include/generated/autoconf.h` を含まない既知の問題があるため、稼働カーネルの config
   （`/boot/config-$(uname -r)` か `/proc/config.gz`）を入れて
   `make olddefconfig modules_prepare` を実行してから `M=` ビルドします。
2. `--apt-headers`: appliance の `/etc/apt/sources.list*` と keyring をコンテナに持ち込み、
   `linux-headers-$(uname -r)` を入れます（TrueNAS が全リリースで配布しているわけではありません）。
3. `--from-source`: [truenas/linux](https://github.com/truenas/linux) の該当ブランチを
   shallow clone して使います。**最後の手段**です。ブランチ先頭は稼働カーネルと同じコミットとは
   限らず、`Module.symvers` も無いため、`CONFIG_MODVERSIONS` が有効な TrueNAS のカーネルでは
   `no symbol version for module_layout` / `Invalid module format` で `insmod` に拒否されます。

### 一般的なディストリビューション

```sh
make                 # /lib/modules/$(uname -r)/build を使う
make check           # W=1 付き
sudo make install    # modules_install + depmod
```

DKMS 用の設定ファイルは用意していません。TrueNAS ではルート FS が更新で入れ替わり、
DKMS の状態が残らないためです。

## インストール（TrueNAS Community Edition）

全体の流れは先頭の「TrueNAS への導入手順（まとめ）」を参照してください。ここは補足です。

```sh
bash ./scripts/install-truenas.sh [target-dir]   # 既定: /mnt/<最初のデータプール>/apps/ugreen-cs201x
```

プール上のデータセットに配置します（`/lib/modules` に置くとシステム更新で消えます）。
引数で配置先を変えられます。ビルド済みの `.ko` があれば一緒にコピーされます。
起動時実行の登録（Init/Shutdown Scripts）はまとめの手順 6 のとおりです。

`ugreen-init.sh` は何度実行しても同じ状態になります。先に fancontrol とモジュールを止めて外し（rmmod）、
insmod → 電源 LED の設定 →
hwmon デバイスの発見 → `fancontrol` 設定の生成 → `fancontrol` 起動までを行い、ログを `ugreen-init.log` に残します。
**現在のカーネル用の `.ko` が無ければ意図的に失敗します**（古い `.ko` を無理に入れない）。

> 旧名 `apps/ugreen-fan` / `ugreen-fan-init.sh` からの移行: Post Init のコマンドを上記の新しいパスに
> 書き換えてください。

### ファン制御（fancontrol）

hwmon になったので lm-sensors の `fancontrol` がそのまま使えます。TrueNAS には
lm-sensors が入っていないため、スクリプト本体を `contrib/fancontrol`（GPL-2.0）として
同梱しています。

hwmon の番号（`hwmon0`, `hwmon3`, …）は起動ごとに変わるので、設定は
`contrib/fancontrol.conf.in` をテンプレートとして持ち、起動時に実際のパスへ展開して
`/run/ugreen-cs201x/fancontrol.conf` を作ります。**編集するのはテンプレート側**です。

システムファン（pwm2）はディスク温度で回します。`ugreen-init.sh` が `drivetemp` モジュール
（SATA ドライブの温度を hwmon に出す）をロードし、`contrib/max-drivetemp` が全ドライブの
最高温度をミリ度で返します（`FCTEMPS` の `!コマンド` 形式）。ドライブの温度が読めないときは
遅いままにならないよう 60 ℃ を返します。カーブは 38〜52 ℃で pwm 40〜255
（45 ℃で約 58 %、50 ℃で約 88 %）で、通常運転で 45 ℃以下、50 ℃超を避ける設定です。
CPU ファン（pwm1）は CPU の NTC のままです。

### ファンカーブの実測

`MINSTOP`（回転を維持できる最低 pwm）と `MINSTART`（停止から回り出す pwm）は機体ごとに
違うので実測します。`pwmconfig` は対話的でディスクを止めるため使いません。

```sh
H=$(grep -l ugreen_cs201x /sys/class/hwmon/hwmon*/name | xargs dirname)
echo 1 > $H/pwm1_enable
for p in 255 200 150 120 100 80 70 60 50 40 30 20; do
    echo $p > $H/pwm1
    sleep 8
    echo "pwm=$p rpm=$(cat $H/fan1_input) duty=$(cat $H/pwm1)"
done
echo 255 > $H/pwm1        # 測定後は必ず戻す
```

回転数が 0 になる直前の値を `MINSTOP`、そこから確実に回り出す値を `MINSTART` に入れます。
`MINPWM` は 0 にせず、常時回しておくのが無難です。

## 検証

```sh
# ロードと hwmon の確認
insmod build/$(uname -r)/ugreen-cs201x.ko
dmesg | tail -5                                   # "found CS201x rev ..., Host2EC window at 0x..."
H=$(grep -l ugreen_cs201x /sys/class/hwmon/hwmon*/name | xargs dirname)
grep . $H/* 2>/dev/null

# pwm が効くか
echo 1 > $H/pwm1_enable; echo 80 > $H/pwm1; sleep 8; cat $H/fan1_input
echo 255 > $H/pwm1;      sleep 8; cat $H/fan1_input

# 温度の妥当性（k10temp や室温と突き合わせる）
cat $H/temp1_input $H/temp2_input
modprobe k10temp && sensors 2>/dev/null | head -20

# リソースリークがないこと
grep -i cs201x /proc/ioports; rmmod ugreen_cs201x; grep -i cs201x /proc/ioports
```

## 既知の未確認事項

実機で確認して、必要ならコードを直す予定の項目です。

- **duty レジスタの読み戻し**: `pwm1` を読んだ値が書いた値と一致しない／常に同じなら
  `pwm_readback=0` で「最後に書いた値」を返すモードに切り替えてください。
- **`FANx_EN = 0` の挙動**: 全開なのか停止なのかが不明。判明すれば `pwm*_enable=0` を
  hwmon の意味どおりに実装できます。
- **NTC の単位**: EC が ℃ を返す前提（ベンダコードもそう扱っている）。`k10temp` や室温と
  大きくずれるならスケール補正が必要です。値が `0x00` / `0xff` のときは、ファン制御を
  誤って弱めないよう `-ENODATA` を返します。
- **DXP2800 GT のファン本数**: ドライバは 2 チャネル出しますが、実機で片方の
  ヘッダが未実装なら `fanN_input` が 0 rpm になります。その場合はテンプレートから
  該当 pwm を削ってください（`ugreen-init.sh` が警告を出します）。

## カーネル更新時

TrueNAS を更新するとカーネル ABI が変わるため、`.ko` を作り直す必要があります。

```sh
cd /mnt/<pool>/apps/ugreen-cs201x
bash ./scripts/build-in-docker.sh
bash ./scripts/ugreen-init.sh
```

再ビルドまでの間、Post-Init は失敗し、ファンは EC 既定の挙動に戻ります
（= 冷却されなくなるわけではありませんが、静音制御は効きません）。

未署名モジュールのロードが Secure Boot / lockdown で拒否される環境では
`insmod` が失敗します。`scripts/collect-hw-info.sh` がその状態も確認します。

## ライセンスと出典

GPL-2.0-only。`ugreen-cs201x-core.c` と `ugreen-cs201x-leds.c` は UGREEN の GPL リリース
[ugreen-opensource/kernel-6.12](https://github.com/ugreen-opensource/kernel-6.12) の
`drivers/ugreen/ug_201x.c`（`SPDX-License-Identifier: GPL-2.0-only`,
Author: Jason.Li \<lijiang@ugreen.com\>）の派生物です。
`contrib/fancontrol` は [lm-sensors](https://github.com/lm-sensors/lm-sensors) の
`prog/pwm/fancontrol`（GPL-2.0）をそのまま同梱しています。

このプロジェクトは UGREEN とも iXsystems とも無関係です。TrueNAS はアプライアンスであり、
カーネルモジュールの追加は想定された使い方ではありません。自己責任で利用してください。
