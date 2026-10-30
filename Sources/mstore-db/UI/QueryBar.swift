import SwiftUI

/// 业务表的查询构建器。
///
/// 设计约束来自内核而不是界面：`Filter` 只有「枚举等值/多值」和「数值上下界」两组自由度，
/// 所以这里只暴露 5 个操作符，**不给做不到的写法留位置**（比如模糊匹配、任意表达式）。
/// 这样界面能保证：看到的每个条件都能翻译成一次位图运算，没有回落全表扫的暗坑。
struct QueryBar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        GlassPanel(padding: 10) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "line.3.horizontal.decrease")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Text(model.query.activeCount == 0 ? "无筛选" : model.query.descriptor)
                        .font(Theme.label(10.5))
                        .foregroundStyle(model.query.activeCount == 0 ? .tertiary : .secondary)
                        .lineLimit(1)
                        .contentTransition(.interpolate)

                    Spacer(minLength: 6)

                    if model.query.activeCount > 0 {
                        Button("清除") {
                            withAnimation(Theme.spring) { model.clearConditions() }
                        }
                        .buttonStyle(.plain)
                        .font(Theme.label(10.5, .medium))
                        .foregroundStyle(.secondary)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    }

                    Button {
                        withAnimation(Theme.spring) { model.addCondition() }
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.glass)
                    .help("加一个条件")
                }

                if !model.query.conditions.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: 6) {
                            ForEach($model.query.conditions) { $condition in
                                ConditionChip(model: model, condition: $condition)
                            }
                        }
                        .padding(.vertical, 1)
                    }
                    .scrollIndicators(.never)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
        .animation(Theme.spring, value: model.query.conditions.count)
        .animation(Theme.quick, value: model.query.descriptor)
    }
}

/// 单个条件：字段 → 操作符 → 值。改任何一处都触发一次防抖查询。
private struct ConditionChip: View {
    @ObservedObject var model: AppModel
    @Binding var condition: QueryCondition

    private var enumValues: [String] {
        model.table?.enumValues[condition.field] ?? []
    }

    private var isNumeric: Bool {
        model.table?.numFields.contains(condition.field) ?? false
    }

    var body: some View {
        HStack(spacing: 5) {
            fieldMenu
            opMenu
            valueEditor
            Button {
                withAnimation(Theme.spring) { model.removeCondition(condition.id) }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("删除这个条件")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.thickMaterial, in: .rect(cornerRadius: Theme.chipRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.chipRadius)
                .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
        )
        .onChange(of: condition) { _, _ in model.scheduleQuery() }
    }

    private var fieldMenu: some View {
        Menu {
            let enums = (model.table?.enumValues.keys.sorted() ?? [])
            let nums = (model.table?.numFields ?? [])
            if !enums.isEmpty {
                Section("枚举") {
                    ForEach(enums, id: \.self) { f in
                        Button(f) { model.changeField(condition.id, to: f) }
                    }
                }
            }
            if !nums.isEmpty {
                Section("数值") {
                    ForEach(nums, id: \.self) { f in
                        Button(f) { model.changeField(condition.id, to: f) }
                    }
                }
            }
        } label: {
            Text(condition.field)
                .font(Theme.mono(11, .medium))
                .foregroundStyle(.primary)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
    }

    private var opMenu: some View {
        Menu {
            ForEach(QueryOp.allCases) { op in
                // 枚举字段不给上下界，数值字段不给「属于其一」：留一个必错的选项只是给人踩
                if isNumeric ? op.needsNumber : !op.needsNumber {
                    Button(op.title + "  " + op.symbol) { condition.op = op }
                }
            }
        } label: {
            Text(condition.op.symbol)
                .font(Theme.mono(11, .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 12)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
    }

    @ViewBuilder private var valueEditor: some View {
        if !condition.op.needsNumber, !enumValues.isEmpty, condition.op == .equals {
            Menu {
                ForEach(enumValues, id: \.self) { v in
                    Button(v) { condition.value = v }
                }
            } label: {
                Text(condition.value.isEmpty ? "选择…" : condition.value)
                    .font(Theme.mono(11))
                    .foregroundStyle(condition.value.isEmpty ? .tertiary : .primary)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .fixedSize()
        } else {
            TextField(condition.op == .anyOf ? "a, b" : "值", text: $condition.value)
                .textFieldStyle(.plain)
                .font(Theme.mono(11))
                .frame(width: condition.op == .anyOf ? 96 : 62)
            if condition.op == .between {
                Text("–").font(Theme.mono(10)).foregroundStyle(.tertiary)
                TextField("上界", text: $condition.upper)
                    .textFieldStyle(.plain)
                    .font(Theme.mono(11))
                    .frame(width: 56)
            }
        }
    }
}
