# rime-tiger

虎整句的独立 Rime 实现。明文码表和字频在构建时转换为紧凑词典，
运行时使用生成数据和 `TCSKNM02` 分页语言模型。

## 安装

运行包应包含已经生成的词典；部署到 Rime 用户目录的必需文件为：

```text
tiger_sentence.schema.yaml
dicts/tiger_sentence_symbols.yaml
lua/tiger_sentence/
```

`lua/tiger_sentence/data/` 必须包含生成的 `lexicon.bin`、`ranks.lua`
和源码中的 `lexicon.lua`。Rime 部署过程不会自动生成这些文件。

运行包解压后位于 `rime/`。将 `tiger_sentence` 合并到已有的
`schema_list`，然后重新部署。已有 `default.custom.yaml` 时，按需合并
包内设置。模型 `sentence-ngram-mobile.bin` 和个人补充语料均可选。

## 从源码构建

在源码根目录使用 Lua 5.4，生成可部署的数据：

```sh
lua tools/build_data.lua dicts/tiger_sentence.codes.txt dicts/tiger_sentence.char_ranks.txt
```

生成物为 `lua/tiger_sentence/data/lexicon.bin` 和
`lua/tiger_sentence/data/ranks.lua`。修改主码表或字频后，需要重新运行
生成器并部署生成数据。修改补充语料或全码白名单不需要重新生成词典。

## 模型

仅支持 `TCSKNM02` 分页模型。模型缺失或初始加载失败时记录一次错误，
并根据码表名次和较少切分进行无模型排序。

模型与程序版本分别维护，文件身份见 `models/sentence-ngram-mobile.meta.yaml`。
下载 Release 中的 `sentence-ngram-mobile.bin` 后，按元数据核对日期和
SHA-256，再将模型放入用户目录的 `models/`，运行包本身不含模型。

## 补充语料

将 `tiger_sentence.supplement.example.txt` 复制为
`tiger_sentence.supplement.txt`，即可添加个人词语。每行格式为
`词条 [权重]`，权重为正整数，默认值为 `1000`。

空行、`#` 注释和无效行会被忽略，重复词条以最后一项为准。
文件支持 BOM、LF 和 CRLF，修改后需要重新部署。

补充语料只调整已有解码路径的候选分数，不会新增编码映射或学习使用频率。

补充奖励不计入提前上屏置信度；奖励改变首选后，自动上屏前缀必须与该首选兼容，并由
原模型概率满足既有阈值。

## 自定义文件

`default.custom.yaml`、`tiger_sentence.custom.yaml` 和其他 Rime 配置
都是明文文件。修改后重新部署即可。包内的 `default.custom.yaml` 是默认补丁，
已有个人配置时需要合并使用。

补充语料和全码白名单也可直接编辑。`dicts/` 下的主码表和字频属于
构建输入，修改后必须重新生成词典。

## 全码白名单

将 `tiger_sentence.full_code_whitelist.example.txt` 复制为根目录的
`tiger_sentence.full_code_whitelist.txt` 后按需调整。名单内的高频字在
`tiger_sentence/high_freq_limit` 大于 `0` 时仍保留非主全码。
每行可写一个或多个字，支持 BOM、LF、CRLF、空行和 `#` 注释；
重复字符会合并。修改后重新部署即可，不需要重新生成词典。

文件不存在时使用空名单。读取、关闭失败或无效 UTF-8 会报告错误。
紧凑词典格式为 `TCSLEX04`，升级时应使用新运行包中的生成数据。

## 输入行为

- 空闲时输入 `/` 加分类编码打开符号候选；编码与候选顺序以
  `dicts/tiger_sentence_symbols.yaml` 为准。单独 `/` 后按空格提交斜杠：
  半角为 `/`，全角为 `／`。
- 空闲时输入 `;` 加字母直接上屏快符；`;;` 上屏 `；`，`;` 后按空格或回车上屏 `：`。
  已有编码时，`;` 仍只选择前方编码在根码表中的第 2 候选。
- 空闲时直接输入数字；全角模式提交全角数字。数字后紧接句点只提交一次半角小数点。
- 字母连续组成整句编码，未上屏部分最多为 128 码；达到上限后不再写入编码或选重后缀，仍可
  退格、浏览或提交候选。已提前上屏的历史编码不占用该预算。
- 一码字只在整段输入就是该一码时生效；更长输入不能拆出裸一码字。
- 单字的最短整码获得候选排序补偿，该补偿不计入提前上屏置信度。
- 默认允许有效码位中的非首选单字参与组句；非首选简词必须显式选重。可关闭“单字重码
  组句”使分段路径只取首选。方案默认过滤前 1,500 个高频字的非主码；若不愿记忆简码，
  可在 `tiger_sentence.custom.yaml` 中将 `tiger_sentence/high_freq_limit` 设为 `0`。
  超过字频表长度的值按表长处理。
- `;`、`'` 和数字分别选择前方码段在根码表中的第 2、第 3 和第 N 候选；不同合法切分
  共同竞争，不强制选择最长码段。数字解析：单独 `0` 表示第 10 项，`01` 等前导零数字
  按数值选重，`00` 等多个零使用隐式排序。
- 空格确认当前候选；没有候选时交给后续 Rime 组件处理。回车提交原始编码，Esc 清空。
- 浏览候选后，本次组合输入暂停提前上屏。
- `Tab` 与 `Shift+Tab` 循环高亮候选，不立即选中或提交。
- 提前上屏要求具有封闭原始编码边界的文本前缀持续达到 `0.995` 置信度：通常需要三个
  追加代，达到 `0.99999` 时需要两个；最多容忍三个中性代。未完成尾码也参与置信度计算，
  距上次提交至少新增并保留三个编码；当前候选池发生 Beam 剪枝时不做概率型提前上屏。
  唯一高置信路径在追加后不再存在有效编码时也可提交已完成部分。

兼容边界及测量记录见 [兼容约定](docs/UPSTREAM.md)。运行时设计和修改
落点见 [开发说明](docs/DEVELOPMENT.md)，版本变化见 [变更日志](CHANGELOG.md)。

## 致谢

本项目的整句解码算法、输入行为、码表、字频和语言模型源自上游虎整句 Rime 实现，
并在此基础上重新组织工程结构。原始输入法来源于 TigerClaw，感谢作者提供的源码。

## 许可

本项目代码采用 [GPL-3.0-only](LICENSE)，来源、兼容范围及性能记录见
[上游兼容说明](docs/UPSTREAM.md)。
