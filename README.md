# ugreen-cs201x

Chipsea **CS201x** EC のファンと温度センサを Linux 標準の **hwmon**、ARGB LED を
**LED クラス**として扱えるようにするカーネルモジュールです。UGREEN NASync の CS201x 搭載機向けで、
動作確認は **DXP2800 GT** で行っています。TrueNAS Community Edition（25.04 以降）向けの
導入スクリプトも含みます。

## 対応チップと機種

対象は Super I/O チップ ID が `0x2011` の **Chipsea CS201x** を積んだ機種です。
動作確認ができているのは **DXP2800 GT だけ**です。

- 既定では、DMI の product name が `DXP2800 GT` の機種でしかロードしません。
- 他の CS201x 搭載機は、モジュールパラメータ `force=1` で DMI の判定を飛ばして試せます
  （チップ ID の確認は残ります）。ただしレジスタ定義は DXP2800 GT 向けのベンダコードに基づくため、
  ファンや LED の本数、レジスタが違う可能性があります。自己責任で試してください。

UGREEN の機種でもチップが違えば動きません。参考：

| 機種 | チップ | 状況 |
|---|---|---|
| DXP2800/4800/4800 Plus/6800/8800/480T Plus, DH2600 | ITE IT8613 | **上流の `it87` ドライバで動く**（このリポジトリは不要）|
| iDX6011 / 6012 / 6011 Pro, DXP4800 GT | ITE IT55xx (ACPI EC 0x62/0x66) | 上流に相当ドライバなし。別途移植が必要 |
| **CS201x 搭載機**（動作確認: DXP2800 GT）| **Chipsea CS201x** | **ここ** |

## TrueNAS への導入

すべて NAS 上で、管理者ユーザー（例: `truenas_admin`）として SSH ログインして行います。
TrueNAS 25.04 以降は `root` での SSH ログインが既定で無効なので、特権が要る操作は `sudo` を付けます。

**事前条件**

- TrueNAS Community Edition 25.04 以降（Linux 6.11 以降。`platform_driver` の `.remove` が `void` を返す API を使うため）
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

2. **ビルド**: Docker コンテナ内で `.ko` を作ります。TrueNAS のルート FS は読み取り専用で、
   システム更新のたびに作り直されるため、NAS 上では apt を使いません。

   ```sh
   sudo bash ./scripts/build-in-docker.sh     # → build/$(uname -r)/ugreen-cs201x.ko
   ```

3. **インストール**: ソース・スクリプト・`.ko` をプール上の `/mnt/<pool>/apps/ugreen-cs201x` にコピーします
   （`/lib/modules` に置くとシステム更新で消えます）。以降はそこにあるものを使います。
   引数で配置先を変えられます。

   ```sh
   sudo bash ./scripts/install-truenas.sh [target-dir]
   ```

4. **手動で一度実行**して動作を確かめます。

   ```sh
   sudo bash /mnt/<pool>/apps/ugreen-cs201x/scripts/ugreen-cs201x-init.sh
   ```

   `dmesg` に `set both fans to pwm 153` と出て、ファンの音が下がれば成功です。失敗した場合は
   同じ場所の `ugreen-cs201x-init.log` と `dmesg` を見てください。

5. **起動時に自動実行**する設定を UI で登録します。

   ```
   System Settings → Advanced → Init/Shutdown Scripts → Add
     Description: ugreen fan and LED setup
     Type:        Command
     Command:     /mnt/<pool>/apps/ugreen-cs201x/scripts/ugreen-cs201x-init.sh
     When:        Post Init
   ```

6. **再起動して確認**します。`ugreen-cs201x-init.log` に新しい起動の記録があり、ファンが 100 % から下がっていれば完了です。

ビルドや動作がうまくいかない場合は、`scripts/collect-hw-info.sh` で環境を確認できます。

### ugreen-cs201x-init.sh の動作

何度実行しても同じ状態になります。先にモジュールを外し（rmmod）、insmod（`init_pwm` でファンを下げる）→
電源 LED の設定 → hwmon デバイスの発見 → `drivetemp` のロードまでを行い、ログを `ugreen-cs201x-init.log` に残します。
**現在のカーネル用の `.ko` が無ければ意図的に失敗します**（古い `.ko` を無理に入れない）。

### ビルド時のカーネルヘッダ

`build-in-docker.sh` は、ビルドに使うカーネルヘッダを次の優先順位で選びます。

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

### TrueNAS を更新したとき

TrueNAS を更新するとカーネル ABI が変わるため、`.ko` を作り直す必要があります。

```sh
cd /mnt/<pool>/apps/ugreen-cs201x
bash ./scripts/build-in-docker.sh
bash ./scripts/ugreen-cs201x-init.sh
```

再ビルドまでの間、Post-Init は失敗し、モジュールが無いのでファンは EC 既定の 100 % のままです。

未署名モジュールのロードが Secure Boot / lockdown で拒否される環境では
`insmod` が失敗します。`scripts/collect-hw-info.sh` がその状態も確認します。

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

`pwm*_enable` は **`1` しか受け付けません**。CS201x に自動制御モードは無く、`FANx_EN` は
PWM 出力のゲートでしかありません。`0` を書くと全開になるのか停止するのかが不明で、
hwmon の意味（`0` = 全開）で受け付けて停止してしまうと機体を焼きかねないので、`-EOPNOTSUPP` を返します。
`pwm_enable=0` が失敗したら `pwm_enable=1` + `pwm=255` に倒す実装（`fancontrol` など）なら、
終了時はファン全開になります。

### モジュールパラメータ

| パラメータ | 既定 | 説明 |
|---|---|---|
| `force` | `0` | DMI の機種判定を飛ばす（チップ ID の確認は残る）|
| `pwm_readback` | `1` | `pwm*` を EC の duty レジスタから読む。読めない機体では `0` にして「最後に書いた値」を返させる |
| `init_pwm` | `-1` | ロード時に両ファンへ書き込む pwm 値（0–255）。`-1` は EC に触らない（→「ファン制御」）|
| `unload_pwm` | `-1` | アンロード時に両ファンへ書き込む pwm 値。`-1` は EC に触らない |

## ファン制御

温度に応じた制御は、hwmon を扱える外部ツールに任せます（このリポジトリに制御ロジックはありません）。
温度は `temp*_input` と、`ugreen-cs201x-init.sh` がロードする `drivetemp`（ドライブ温度）から読めます。

EC は電源投入時にファンを 100 % で回します。`ugreen-cs201x-init.sh` はロード直後に、これを
`INIT_PWM`（既定 153 = 約 60 %）へ下げます。外部ツールが動き出すまで、ファンはこの値のままです。

- 153 は、ドライブ温度が 42–45 ℃で推移する構成なら、制御が起動しないままでも 46 ℃を超えないと
  見込んだ値です。`INIT_PWM=128`（50 %）程度までは下げられますが、100 を切る値は
  制御が起動しなかったときに危険です。
- `INIT_PWM=` と空にすると `init_pwm` を渡さず、EC には触りません。
- 制御ツールが止まると、ファンは最後に書かれた pwm のままです。自動で再起動する設定にしてください。

## ベンダコードとの差分

`ug_201x.c` からレジスタマップとアクセス手順はそのまま引き継ぎ、以下を変えています。

- procfs ではなく hwmon (`devm_hwmon_device_register_with_info`) で公開
- **EC の I/O ウィンドウを `devm_request_region()` で確保**し、`acpi_check_resource_conflict()`
  で ACPI の予約と衝突しないか確認する。ファームウェアが先に予約している場合（DXP2800 GT で確認した例では
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

前面の ARGB LED（DXP2800 GT で確認した構成は power / LAN / disk1 / disk2）は、ファンと同じ EC のレジスタ空間にあります。
EC の I/O ウィンドウとロックは `ugreen-cs201x-core.c` が持ち、LED のコードは同じモジュール内から
専用の関数経由でそれを借ります。I/O ポートには直接触れず、
アクセスできる EC アドレスも LED のブロックだけに限られます（ファンのレジスタには届きません）。
そのため、**先に `ugreen-cs201x` をロードしてください**（`ugreen-cs201x-init.sh` はその順で行います）。

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
`ugreen-cs201x-init.sh` は夜に眩しくないよう、電源 LED を **暗い緑の常時点灯**（`multi_intensity` が `0 3 0`）に
設定します。明るさを変えたいときは、スクリプト先頭付近の `POWER_LED_RGB` の緑の値（0〜255）を書き換えてください。

### LAN のアクティビティに連動させる

```sh
modprobe ledtrig-netdev
L=/sys/class/leds/ugreen:rgb:lan
echo netdev > $L/trigger
echo enp1s0 > $L/device_name            # 実際のインタフェース名に置き換える
echo 1 > $L/link; echo 1 > $L/tx; echo 1 > $L/rx
```

## TrueNAS 以外でのビルド

```sh
make                 # /lib/modules/$(uname -r)/build を使う
make check           # W=1 付き
sudo make install    # modules_install + depmod
```

DKMS 用の設定ファイルは用意していません。TrueNAS ではルート FS が更新で入れ替わり、
DKMS の状態が残らないためです。

## ライセンスと出典

GPL-2.0-only。`ugreen-cs201x-core.c` と `ugreen-cs201x-leds.c` は UGREEN の GPL リリース
[ugreen-opensource/kernel-6.12](https://github.com/ugreen-opensource/kernel-6.12) の
`drivers/ugreen/ug_201x.c`（`SPDX-License-Identifier: GPL-2.0-only`,
Author: Jason.Li \<lijiang@ugreen.com\>）の派生物です。

このプロジェクトは UGREEN とも iXsystems とも無関係です。TrueNAS はアプライアンスであり、
カーネルモジュールの追加は想定された使い方ではありません。自己責任で利用してください。
