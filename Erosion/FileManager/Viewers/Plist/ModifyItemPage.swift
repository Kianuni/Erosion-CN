//
//  ModifyItemPage.swift
//  Filos
//
//  Created by lunginspector on 7/25/26.
//

import SwiftUI

struct ModifyItemPage: View {
    @EnvironmentObject private var pmgr: PlistManager
    @Environment(\.dismiss) var dismiss
    
    @State var ogItem: PlistItem
    @State private var draftItem: PlistItem
    @Binding var item: PlistItem
    @State private var isEditing = false
    
    init(item: Binding<PlistItem>) {
        self._item = item
        self._ogItem = State(initialValue: item.wrappedValue)
        self._draftItem = State(initialValue: item.wrappedValue)
    }
    
    private var activeBinding: Binding<PlistItem> {
        isEditing ? $draftItem : $item
    }
    
    var body: some View {
        List {
            Section {
                if isEditing {
                    TextField("键名 (Key)", text: $draftItem.key)
                } else {
                    Text(item.key)
                }
                Picker("类型", selection: activeBinding.type) {
                    ForEach(PlistItemType.allCases, id: \.self) { type in
                        if type != .unknown {
                            Text(type.label).id(type)
                        }
                    }
                }
                .disabled(!isEditing)
                .onChange(of: draftItem.type) { _, newType in
                    if newType == .bool {
                        draftItem.stringVal = draftItem.boolVal ? "true" : "false"
                    }
                }
            } header: {
                HeaderLabel("属性标识", symbol: "creditcard")
            }
            
            Section {
                switch activeBinding.wrappedValue.type {
                case .dict, .array:
                    Button("添加子项") {
                        draftItem.dictVal.insert(PlistItem(key: "New Item", value: "", isModified: true), at: 0)
                    }
                    .disabled(!isEditing)
                    ForEach(activeBinding.dictVal) { $nestItem in
                        ItemRow(item: $nestItem, hierarchy: 0).environmentObject(pmgr)
                            .disabled(isEditing && nestItem.key == "New Item")
                            .swipeActions {
                                if isEditing {
                                    Button(role: .destructive) {
                                        draftItem.dictVal.removeAll { $0.id == nestItem.id }
                                    } label: {
                                        Image(systemName: "trash")
                                    }
                                }
                            }
                    }
                case .data:
                    Text(activeBinding.wrappedValue.stringVal)
                case .bool:
                    Toggle(activeBinding.wrappedValue.boolVal ? L("开启 (True)") : L("关闭 (False)"), isOn: activeBinding.boolVal)
                        .disabled(!isEditing)
                        .onChange(of: draftItem.boolVal) { newVal in
                            draftItem.stringVal = newVal ? "true" : "false"
                        }
                default:
                    TextField(activeBinding.wrappedValue.type.label, text: activeBinding.stringVal)
                        .disabled(!isEditing)
                }
            } header: {
                if activeBinding.wrappedValue.type == .dict || activeBinding.wrappedValue.type == .array {
                    HeaderLabel(L("键值 (\(activeBinding.wrappedValue.dictVal.count) 项)"), symbol: "character.cursor.ibeam")
                } else {
                    HeaderLabel("键值", symbol: "character.cursor.ibeam")
                }
            }
            
            if isEditing {
                Button("删除此项", role: .destructive) {
                    let res = pmgr.writePlistItems(delItem: item)
                    if !res {
                        Alertinator.shared.alert(title: L("删除 Plist 项目失败！"), body: Errors.checkLogs)
                    } else {
                        dismiss()
                    }
                }
            }
        }
        .navigationTitle("\(activeBinding.wrappedValue.key)")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(isEditing)
        .listStyle(.grouped)
        .onAppear {
            if !isEditing {
                ogItem = item
                draftItem = item
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if isEditing {
                    Button {
                        draftItem = ogItem
                        item = ogItem
                        isEditing = false
                    } label: {
                        ToolbarLabel("取消", symbol: "xmark")
                    }
                }
            }
            
            ToolbarItem(placement: .topBarTrailing) {
                if isEditing {
                    Button(role: .adaptiveConfirm) {
                        draftItem.isModified = true
                        if draftItem.type != .data {
                            draftItem.rawVal = nil
                        }
                        let res = pmgr.writePlistItems(newItem: draftItem)
                        if res {
                            item = draftItem
                            ogItem = draftItem
                            Haptic.shared.play(.soft)
                        } else {
                            Alertinator.shared.alert(title: L("写入 Plist 失败！"), body: Errors.checkLogs)
                            draftItem = ogItem
                            item = ogItem
                        }
                        isEditing = false
                    } label: {
                        ToolbarLabel("保存", symbol: "checkmark")
                    }
                } else {
                    if pmgr.isWritable {
                        Button {
                            ogItem = item
                            draftItem = item
                            isEditing = true
                        } label: {
                            ToolbarLabel("编辑", symbol: "pencil")
                        }
                    }
                }
            }
        }
    }
}
