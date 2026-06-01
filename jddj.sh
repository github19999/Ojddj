证书存储路径:
  1) /etc/ssl/private/ [默认]
  2) /etc/nginx/ssl/
  3) /etc/apache2/ssl/
  4) 自定义
请选择 (1-4): 1
[STEP] 安装 acme.sh...
  % Total    % Received % Xferd  Average Speed   Time    Time     Time  Current
                                 Dload  Upload   Total   Spent    Left  Speed
100  243k  100  243k    0     0  4194k      0 --:--:-- --:--:-- --:--:-- 4270k
[Mon Jun  1 14:24:53 UTC 2026] Installing from online archive.
[Mon Jun  1 14:24:53 UTC 2026] Downloading https://github.com/acmesh-official/acme.sh/archive/master.tar.gz
[Mon Jun  1 14:24:53 UTC 2026] Extracting master.tar.gz
[Mon Jun  1 14:24:53 UTC 2026] It is recommended to install crontab first. Try to install 'cron', 'crontab', 'crontabs' or 'vixie-cron'.
[Mon Jun  1 14:24:53 UTC 2026] We need to set a cron job to renew the certs automatically.
[Mon Jun  1 14:24:53 UTC 2026] Otherwise, your certs will not be able to be renewed automatically.
[Mon Jun  1 14:24:53 UTC 2026] Please add '--force' and try install again to go without crontab.
[Mon Jun  1 14:24:53 UTC 2026] ./acme.sh --install --force
[Mon Jun  1 14:24:53 UTC 2026] Pre-check failed, cannot install.
[ERROR] acme.sh 安装失败，未找到 /root/.acme.sh/acme.sh
