# 知识库数据库版本管理指南

## 如何添加新版本

当发布新的知识库数据库版本时，按照以下步骤更新 `index.html`：

### 1. 上传新文件
将新的数据库文件（如 `knowledge-1.3.1.db`）上传到 `www/` 目录。

### 2. 更新 HTML
在 `index.html` 的 `<div class="version-list">` 部分添加新版本：

```html
<a href="knowledge-1.3.1.db" download class="version-item">
  <div class="version-info">
    <span class="version-name">v1.3.1</span>
    <span class="version-date">2025-05-15</span>
  </div>
  <div class="version-meta">
    <span class="version-size">70 KB</span>
    <svg width="20" height="20" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24">
      <path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/>
      <polyline points="7 10 12 15 17 10"/>
      <line x1="12" y1="15" x2="12" y2="3"/>
    </svg>
  </div>
</a>
```

### 3. 标记最新版本
如果要标记某个版本为"Latest"，在该版本的 `version-date` 元素上添加 `data-i18n="knowledge_latest"` 属性：

```html
<span class="version-date" data-i18n="knowledge_latest">Latest</span>
```

其他历史版本直接显示日期即可：

```html
<span class="version-date">2025-05-10</span>
```

## 版本列表示例

```html
<div class="version-list">
  <!-- 最新版本 -->
  <a href="knowledge-1.3.2.db" download class="version-item">
    <div class="version-info">
      <span class="version-name">v1.3.2</span>
      <span class="version-date" data-i18n="knowledge_latest">Latest</span>
    </div>
    <div class="version-meta">
      <span class="version-size">72 KB</span>
      <svg width="20" height="20" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24">
        <path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/>
        <polyline points="7 10 12 15 17 10"/>
        <line x1="12" y1="15" x2="12" y2="3"/>
      </svg>
    </div>
  </a>
  
  <!-- 历史版本 -->
  <a href="knowledge-1.3.1.db" download class="version-item">
    <div class="version-info">
      <span class="version-name">v1.3.1</span>
      <span class="version-date">2025-05-15</span>
    </div>
    <div class="version-meta">
      <span class="version-size">70 KB</span>
      <svg width="20" height="20" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24">
        <path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/>
        <polyline points="7 10 12 15 17 10"/>
        <line x1="12" y1="15" x2="12" y2="3"/>
      </svg>
    </div>
  </a>
  
  <a href="knowledge-1.3.0.db" download class="version-item">
    <div class="version-info">
      <span class="version-name">v1.3.0</span>
      <span class="version-date">2025-05-10</span>
    </div>
    <div class="version-meta">
      <span class="version-size">68 KB</span>
      <svg width="20" height="20" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24">
        <path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/>
        <polyline points="7 10 12 15 17 10"/>
        <line x1="12" y1="15" x2="12" y2="3"/>
      </svg>
    </div>
  </a>
</div>
```

## 注意事项

1. **版本号格式**：建议使用语义化版本号（如 v1.3.0, v1.3.1, v1.4.0）
2. **文件大小**：确保 `version-size` 显示准确的文件大小
3. **日期格式**：使用 `YYYY-MM-DD` 格式（如 2025-05-15）
4. **最新版本**：始终保持只有一个版本标记为 "Latest"
5. **排序**：建议按版本从新到旧排列（最新版本在最上面）

## 多语言支持

版本列表中的文本已经支持中英文切换：
- "Knowledge Database Versions" / "知识库数据库版本"
- "Download the knowledge database..." / "下载知识库数据库..."
- "Latest" / "最新版本"

无需额外配置，切换语言时会自动更新。
