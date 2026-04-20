let registry = ToolRegistry()
registry.registerBuiltIns()      // write_file, read_file, edit_file, list_files, etc.
registry.register(KBSearchTool()) // your custom tool
