// 在隔离的示例目录中部署真实方案，逐键检查符号及整句上下文
#include <rime_api.h>

#include <cstdlib>
#include <ctime>
#include <iostream>
#include <sstream>
#include <string>
#include <utility>
#include <vector>

static RimeApi *running_api = nullptr;

static void check(bool value, const std::string &message) {
  if (!value) {
    std::cerr << message << '\n';
    if (running_api)
      running_api->finalize();
    std::exit(1);
  }
}

// 十六进制字段保留空串、制表符及 UTF-8 字节，供逐键差分工具读取
static std::string hex(const std::string &value) {
  const char *digits = "0123456789abcdef";
  std::string result;
  for (unsigned char ch : value) {
    result += digits[ch >> 4];
    result += digits[ch & 15];
  }
  return result;
}

int main(int argc, char **argv) {
  check(argc == 3 || (argc == 4 && std::string(argv[3]) == "--trace"),
        "需要隔离的示例目录、共享配置目录及可选的 --trace");
  auto *api = rime_get_api();
  RIME_STRUCT(RimeTraits, traits);
  traits.user_data_dir = argv[1];
  traits.shared_data_dir = argv[2];
  traits.app_name = "rime.tiger_symbols_test";
  traits.min_log_level = 2;
  traits.log_dir = argv[1];
  api->setup(&traits);
  api->initialize(&traits);
  running_api = api;
  check(api->find_module("lua"), "缺少 librime-lua");
  api->deployer_initialize(&traits);
  const std::string schema =
      std::string(argv[1]) + "/tiger_sentence.schema.yaml";
  check(api->deploy_schema(schema.c_str()), "示例方案部署失败");
  auto session = api->create_session();
  check(session && api->select_schema(session, "tiger_sentence"),
        "方案加载失败");
  auto commit = [&]() {
    RIME_STRUCT(RimeCommit, result);
    std::string text;
    if (api->get_commit(session, &result)) {
      text = result.text;
      api->free_commit(&result);
    }
    return text;
  };
  auto type = [&](const std::string &input) {
    std::string prefix;
    for (unsigned char key : input) {
      prefix += key;
      check(api->process_key(session, key, 0), "按键未处理：" + prefix);
      const auto text = commit();
      check(text.empty(), "输入 " + prefix + " 时提前提交：" + text);
      check(api->get_input(session) == prefix, "原始输入不符：" + prefix);
    }
  };
  auto candidates = [&]() {
    std::vector<std::string> texts;
    RimeCandidateListIterator it{};
    check(api->candidate_list_begin(session, &it), "候选列表不可用");
    while (api->candidate_list_next(&it))
      texts.emplace_back(it.candidate.text);
    api->candidate_list_end(&it);
    return texts;
  };
  if (argc == 4) {
    std::string line;
    while (std::getline(std::cin, line)) {
      std::istringstream input(line);
      std::string id;
      int early, duplicate, key;
      check(bool(input >> id >> early >> duplicate), "差分输入格式错误");
      api->destroy_session(session);
      session = api->create_session();
      check(session && api->select_schema(session, "tiger_sentence"),
            "差分会话加载失败");
      api->set_option(session, "ascii_mode", false);
      api->set_option(session, "tiger_sentence_early_commit", early);
      api->set_option(session, "tiger_sentence_allow_duplicate_single",
                      duplicate);
      int step = 0;
      while (input >> key) {
        const auto started = std::clock();
        const bool handled = api->process_key(session, key, 0);
        const auto output = commit();
        const std::string raw = api->get_input(session);
        RIME_STRUCT(RimeContext, context);
        std::string preedit;
        if (api->get_context(session, &context)) {
          if (context.composition.preedit)
            preedit = context.composition.preedit;
          api->free_context(&context);
        }
        std::vector<std::string> texts;
        RimeCandidateListIterator it{};
        if (api->candidate_list_begin(session, &it)) {
          while (api->candidate_list_next(&it))
            texts.emplace_back(it.candidate.text);
          api->candidate_list_end(&it);
        }
        const double micros = 1e6 * (std::clock() - started) / CLOCKS_PER_SEC;
        std::cout << id << '\t' << step++ << '\t' << handled << '\t'
                  << hex(output) << '\t' << hex(raw) << '\t' << hex(preedit)
                  << '\t' << micros;
        for (const auto &value : texts)
          std::cout << '\t' << hex(value);
        std::cout << '\n';
      }
    }
    api->destroy_session(session);
    api->finalize();
    return 0;
  }
  for (bool full_shape : {false, true}) {
    api->set_option(session, "ascii_mode", false);
    api->set_option(session, "full_shape", full_shape);
    type("/szq");
    check(candidates() == std::vector<std::string>{"①", "②", "③", "④", "⑤", "⑥",
                                                   "⑦", "⑧", "⑨", "⑩"},
          "/szq 候选不符");
    check(api->process_key(session, '=', 0), "分页失败");
    check(api->process_key(session, '5', 0), "选重失败");
    check(commit() == "⑩", "/szq 第二页第五项提交不符");
    type("/");
    check(candidates() == std::vector<std::string>{full_shape ? "／" : "/"},
          "单独斜杠候选不符");
    check(api->process_key(session, ' ', 0), "斜杠空格提交失败");
    check(commit() == (full_shape ? "／" : "/"), "斜杠标点提交不符");
    type(";");
    check(api->process_key(session, 'a', 0), "分号快符失败");
    check(commit() == "！", "分号快符提交不符");
  }
  for (bool full_shape : {false, true}) {
    api->set_option(session, "full_shape", full_shape);
    check(api->process_key(session, '[', 0), "左括号按键未处理");
    check(commit() == "【", "左括号未按标点配置直接提交");
    check(std::string(api->get_input(session)).empty(),
          "左括号提交后仍有组合输入");
    check(api->process_key(session, ']', 0), "右括号按键未处理");
    check(commit() == "】", "右括号未按标点配置直接提交");
    check(std::string(api->get_input(session)).empty(),
          "右括号提交后仍有组合输入");
  }
  api->set_option(session, "full_shape", false);
  api->set_option(session, "tiger_sentence_allow_duplicate_single", true);
  struct SentenceCase {
    std::string raw, text, preedit, committed, early_preedit;
  };
  for (bool early : {false, true}) {
    api->set_option(session, "tiger_sentence_early_commit", early);
    for (const auto &test : std::vector<SentenceCase>{
             {"xrxbj", "反刍", "xr xbj", "反", "xbj"},
             {"korylkugkugkskorkor", "汨罗江江水汩汩",
              "kor yl kug kug ks kor kor", "汨罗江", "kug ks kor kor"},
             {"kormylkugkugkskorgkorg", "汨罗江江水汩汩",
              "korm yl kug kug ks korg korg", "汨罗",
              "kug kug ks korg korg"}}) {
      std::string output, prefix;
      for (unsigned char key : test.raw) {
        prefix += key;
        check(api->process_key(session, key, 0), "整句按键未处理：" + test.raw);
        output += commit();
        if (early && prefix == "xrx")
          check(output == "反" && std::string(api->get_input(session)) == "x",
                "反的空码上屏边界不符");
      }
      const auto texts = candidates();
      check(!texts.empty() && output + texts.front() == test.text,
            "整句上下文丢失：" + test.raw + "，实际为 " + output +
                (texts.empty() ? "（无候选）" : texts.front()));
      check(output == (early ? test.committed : ""), "已提交前缀与预期不符");
      if (early && test.raw == "korylkugkugkskorkor")
        check(texts ==
                  std::vector<std::string>{"江水汩汩", "江水旭旭", "过劫汩汩",
                                           "江水汨汨", "毋劫汩汩", "过劫旭旭",
                                           "江氵汩汩", "江厶汩汩", "江水测对日",
                                           "毋劫旭旭", "过劫汨汨", "江水沓旭",
                                           "江水旭沓", "江水汨旭", "江水旮旭",
                                           "毌劫汩汩", "江氵旭旭", "江水汩旭"},
              "前缀过滤时机改变了候选窗口");
      RIME_STRUCT(RimeContext, context);
      check(api->get_context(session, &context), "整句上下文不可用");
      check(context.composition.preedit, "整句预编辑不可用");
      const std::string preedit = context.composition.preedit;
      api->free_context(&context);
      const std::string expected = early ? test.early_preedit : test.preedit;
      check(preedit == expected, "整句切分不符：" + preedit);
      check(api->process_key(session, ' ', 0), "整句空格提交失败");
      check(output + commit() == test.text, "整句提交不符：" + test.raw);
    }
  }
  api->set_option(session, "tiger_sentence_allow_duplicate_single", false);
  for (const auto &test : std::vector<std::pair<std::string, std::string>>{
           {"xrxbj", "反秉"}, {"xrxbj;", "反刍"}}) {
    std::string output;
    for (unsigned char key : test.first) {
      check(api->process_key(session, key, 0), "选重按键未处理");
      output += commit();
    }
    check(api->process_key(session, ' ', 0), "选重提交失败");
    check(output + commit() == test.second,
          "续句没有遵守单字重码开关或显式选重");
  }
  api->set_option(session, "tiger_sentence_allow_duplicate_single", true);
  type("xr");
  check(api->process_key(session, 'x', 0) && commit() == "反",
        "会话前缀未提交");
  const auto first_session = session;
  session = api->create_session();
  check(session && api->select_schema(session, "tiger_sentence"),
        "第二会话加载失败");
  api->set_option(session, "ascii_mode", false);
  type("xbj");
  const auto second_candidates = candidates();
  check(!second_candidates.empty() && second_candidates.front() == "秉",
        "第二会话错误继承了反的上下文");
  check(api->destroy_session(session), "第二会话释放失败");
  session = first_session;
  for (unsigned char key : std::string("bj"))
    check(api->process_key(session, key, 0), "第一会话续句失败");
  const auto first_candidates = candidates();
  check(!first_candidates.empty() && first_candidates.front() == "刍",
        "第二会话释放时清除了第一会话上下文");
  check(api->process_key(session, ' ', 0) && commit() == "刍",
        "第一会话提交不符");
  check(api->destroy_session(session), "会话释放失败");
  api->finalize();
}
