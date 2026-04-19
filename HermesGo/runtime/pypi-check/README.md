# pypi-check

This folder stores wheel files used for package checks during build verification.
这个目录保存构建验证时使用的 wheel 文件。

## Contents / 内容

- `hermes-0.9.1-py3-none-any.whl`
  - Local wheel used to verify the packaged Python environment / 用于验证打包后的 Python 环境的本地 wheel

## Notes / 说明

- This is a build artifact cache, not a user-facing data directory.
- Keep it for deterministic rebuild checks.
- 这里是构建产物缓存，不是面向用户的数据目录。
- 保留它，重建校验结果保持一致。
