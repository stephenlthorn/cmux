extension SidebarDocStore {
    /// Where the sidebar's rows are known: the first load settled, and when it loaded, the sidebar draws it (`shown`, a
    /// hop after the load). Until then a move sent on the older path is one the document ignores once it loads.
    public var firstShowSettled: Bool { firstLoadSettled && (!isActive || shown != nil) }
}
