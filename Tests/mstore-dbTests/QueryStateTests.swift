import Testing
@testable import mstore_db

// 这些用例只覆盖「纯逻辑」：命令行条件 → Filter → 描述串。
// UI 要靠人看截图，但这一段是唯一能把「用户输入」变成「内核请求」的地方，
// 出了偏差不会崩，只会安静地查错数据——所以必须有断言。

@Suite("命令行条件解析")
struct ParseTests {
    @Test("等值")
    func equals() {
        let c = QueryState.parse("dept=R&D")
        #expect(c.count == 1)
        #expect(c[0].field == "dept")
        #expect(c[0].op == .equals)
        #expect(c[0].value == "R&D")
    }

    @Test("不小于与不大于")
    func bounds() {
        let c = QueryState.parse("level>=5;level2<=3")
        #expect(c.count == 2)
        #expect(c[0].op == .atLeast)
        #expect(c[0].value == "5")
        #expect(c[1].op == .atMost)
        // 字段名里带数字不能被当成操作符的一部分
        #expect(c[1].field == "level2")
        #expect(c[1].value == "3")
    }

    @Test("逗号多值走 anyOf")
    func anyOf() {
        let c = QueryState.parse("status=active,leave")
        #expect(c.count == 1)
        #expect(c[0].op == .anyOf)
        #expect(c[0].field == "status")
        #expect(c[0].value == "active,leave")
    }

    @Test("没有操作符的片段被丢掉，而不是猜")
    func garbage() {
        #expect(QueryState.parse("dept").isEmpty)
        #expect(QueryState.parse("").isEmpty)
        // 分号产生的空片段同样丢掉
        #expect(QueryState.parse("a=1;;b=2").count == 2)
    }

    @Test("值里再出现等号时，只切第一个")
    func embeddedEquals() {
        let c = QueryState.parse("expr=a=b")
        #expect(c.count == 1)
        #expect(c[0].field == "expr")
        #expect(c[0].value == "a=b")
    }

    @Test(">= 优先于 <=，且都优先于 =")
    func precedence() {
        // "a>=1" 若先匹配 "="，会得到 field "a>"，值 "1" —— 这是个真实的排序陷阱
        let c = QueryState.parse("a>=1")
        #expect(c.count == 1)
        #expect(c[0].field == "a")
        #expect(c[0].op == .atLeast)
    }

    @Test("两端空白被吃掉——字段名上留下空格会让内核静默查空")
    func trimming() {
        let c = QueryState.parse("  dept = R&D  ")
        #expect(c.count == 1)
        #expect(c[0].field == "dept")
        #expect(c[0].value == "R&D")

        let n = QueryState.parse(" level >= 5 ")
        #expect(n[0].field == "level")
        #expect(n[0].value == "5")
    }
}

@Suite("条件合法性")
struct ValidityTests {
    @Test("空值一律无效")
    func emptyValue() {
        #expect(!QueryCondition(field: "a", op: .equals, value: "").isValid)
        #expect(!QueryCondition(field: "a", op: .equals, value: "   ").isValid)
    }

    @Test("数值操作符要求能解析成 Double")
    func numericOnly() {
        #expect(QueryCondition(field: "a", op: .atLeast, value: "5").isValid)
        #expect(!QueryCondition(field: "a", op: .atLeast, value: "five").isValid)
        // 枚举等值不要求数字
        #expect(QueryCondition(field: "a", op: .equals, value: "R&D").isValid)
    }

    @Test("between 缺上界无效")
    func between() {
        #expect(!QueryCondition(field: "a", op: .between, value: "1", upper: "").isValid)
        #expect(!QueryCondition(field: "a", op: .between, value: "1", upper: "x").isValid)
        #expect(QueryCondition(field: "a", op: .between, value: "1", upper: "9").isValid)
    }

    @Test("needsNumber 只对三个数值操作符为真")
    func needsNumber() {
        #expect(!QueryOp.equals.needsNumber)
        #expect(!QueryOp.anyOf.needsNumber)
        #expect(QueryOp.atLeast.needsNumber)
        #expect(QueryOp.atMost.needsNumber)
        #expect(QueryOp.between.needsNumber)
    }
}

@Suite("条件转 Filter")
struct PayloadTests {
    private func state(_ conditions: [QueryCondition], limit: Int = 300) -> QueryState {
        QueryState(conditions: conditions, limit: limit)
    }

    @Test("同一字段后者覆盖前者，不偷偷合并")
    func lastWins() {
        let s = state([
            QueryCondition(field: "level", op: .atLeast, value: "3"),
            QueryCondition(field: "level", op: .atLeast, value: "7"),
        ])
        #expect(s.payload().gte["level"] == 7)
        #expect(s.activeCount == 2)
        // 描述串只反映最终生效的那个
        #expect(s.descriptor == "level ≥ 7")
    }

    @Test("无效条件不进 Filter，也不计入 activeCount")
    func skipInvalid() {
        let s = state([
            QueryCondition(field: "level", op: .atLeast, value: "oops"),
            QueryCondition(field: "dept", op: .equals, value: "R&D"),
        ])
        let f = s.payload()
        #expect(f.gte.isEmpty)
        #expect(f.eq["dept"] == ["R&D"])
        #expect(s.activeCount == 1)
    }

    @Test("anyOf 切分后去空白、丢空项")
    func anyOfSplit() {
        let s = state([QueryCondition(field: "s", op: .anyOf, value: "a, b ,, c ")])
        #expect(s.payload().eq["s"] == ["a", "b", "c"])
    }

    @Test("between 同时填 gte 与 lte")
    func between() {
        let s = state([QueryCondition(field: "ms", op: .between, value: "10", upper: "20")])
        let f = s.payload()
        #expect(f.gte["ms"] == 10)
        #expect(f.lte["ms"] == 20)
    }

    @Test("空状态描述为「全部行」")
    func empty() {
        #expect(state([]).descriptor == "全部行")
        #expect(state([]).payload().isEmpty)
    }
}

@Suite("描述串")
struct DescriptorTests {
    @Test("字段按字典序，数值带单位分隔符")
    func ordering() {
        var f = FilterPayload()
        f.eq["status"] = ["active"]
        f.gte["level"] = 5
        f.lte["ms"] = 100
        // 三段之间是两个空格 + 中点 + 两个空格；顺序固定才便于和日志比对
        #expect(f.descriptor == "status = active  ·  level ≥ 5  ·  ms ≤ 100")
    }

    @Test("多值用集合写法")
    func multiValue() {
        var f = FilterPayload()
        f.eq["status"] = ["active", "leave"]
        #expect(f.descriptor == "status ∈ {active, leave}")
    }

    @Test("整数不带小数点，小数保留两位")
    func numberFormat() {
        var f = FilterPayload()
        f.gte["a"] = 5
        f.lte["b"] = 2.5
        #expect(f.descriptor == "a ≥ 5  ·  b ≤ 2.50")
    }
}
