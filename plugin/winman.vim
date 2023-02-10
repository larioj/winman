vim9script

g:winman_explorer_width = get(g:, 'winman_explorer_width', 30)
g:winman_window_width = get(g:, 'winman_window_width', 80)
g:winman_explorer_filetype = get(g:, 'winman_explorer_filetype', 'nerdtree')

def WinLayout(): list<any>
  var [type, fragment] = winlayout()
  if type == 'leaf'
    type = 'col'
    fragment = [[type, fragment]]
  endif
  if type == 'col'
    type = 'row'
    fragment = [[type, fragment]]
  endif
  return [type, fragment]
enddef

def Flatten(fragment: list<any>): list<number>
  var result = []
  var unexplored = [fragment]
  while len(unexplored) > 0
    var [type, children] = remove(unexplored, -1)
    if type == 'leaf'
      add(result, children)
    else
      extend(unexplored, reverse(copy(children)))
    endif
  endwhile
  return result
enddef

def Layout(winlayout: list<any> = WinLayout()): dict<any>
  var windows = mapnew(winlayout[1], (_, frament) => Flatten(frament))
  return {'windows': windows, thonks: []}
enddef

def LocationOf(layout: dict<any>, window: number): list<number>
 for group in range(len(layout.windows))
   const idx = index(layout.windows[group], window)
   if idx != -1
     return [group, idx]
   endif
 endfor
 return [-1, -1]
enddef

def MoveToExplorerPosition(layout: dict<any>, window: number)
  const [group, idx] = LocationOf(layout, window)
  remove(layout.windows[group], idx)
  insert(layout.windows, [window], 0)
  add(layout.thonks, 'wincmd H')
enddef

def WinSplitMoveThonk(child: number, parent: number, vertical: bool = false, rightbelow: bool = false): string
  return printf("win_splitmove(%d, %d, {'vertical': %s, 'rightbelow': %s})", child, parent, vertical, rightbelow)
enddef

def WinSplitMove(layout: dict<any>, child: number, parent: number, vertical: bool = false, rightbelow: bool = false)
  const [child_group, child_idx] = LocationOf(layout, child)
  remove(layout.windows[child_group], child_idx)
  if len(layout.windows[child_group]) == 0
    remove(layout.windows, child_group)
  endif
  const [parent_group, parent_idx] = LocationOf(layout, parent)
  if vertical
    const new_child_group = parent_group + (rightbelow ? 1 : 0)
    insert(layout.windows, [child], new_child_group)
  else
    const new_child_idx = parent_idx + (rightbelow ? 1 : 0)
    insert(layout.windows[parent_group], child, new_child_idx)
  endif
  add(layout.thonks, WinSplitMoveThonk(child, parent, vertical, rightbelow))
enddef

def Filetypes(): dict<any>
  var fts = {}
  for i in range(winnr('$'))
    const nr = i + 1
    fts[win_getid(nr)] = getwinvar(nr, '&filetype')
  endfor
  return fts
enddef

def MaxGroups(columns: number, window_width: number): number
  const max_groups = columns / window_width
  if columns % window_width >= max_groups - 1
    return max_groups
  endif
  return max_groups - 1
enddef

def IsExplorer(env: dict<any>, window: number): bool
  return (env.filetypes)[window] == env.winman_explorer_filetype
enddef

def HasExplorer(env: dict<any>): bool
  return indexof(env.layout.windows[0], (_, w) => IsExplorer(env, w)) != -1
enddef

def Find(items: list<any>, Pred: func(any): bool, start: number = 0, direction: number = 1): number
  var i = start
  while i >= 0 && i < len(items)
    if Pred(items[i])
      return i
    endif
    i += direction
  endwhile
  return -1
enddef

def GroupSizes(layout: dict<any>)
  return mapnew(layout.windows, (_, g) => len(g))
enddef

def PercolateFrom(env: dict<any>, group: number, group_deltas: list<number>, direction: number)
  var target_group = Find(group_deltas, (delta) => delta == 0, group, direction)
  while target_group != group
    const group_sizes = GroupSizes(env.layout)
    var start_group = Find(group_sizes, (size) => size > 1, target_group - direction, -direction)
    var cur_group = start_group
    while cur_group != target_group
      MoveFrom(env, cur_group, direction)
      cur_group += direction
    endwhile
    target_group = start_group
  endwhile
enddef

def BalanceAfterInsert(env: dict<any>, parent: number, child: number)
  const group = LocationOf(env.layout, child)[0]
  const group_sizes = GroupSizes(env.layout)
  const min_size = min(group_sizes[1 : ])
  var group_deltas = mapnew(group_sizes, (_, s) => s - min_size)
  group_deltas[0] = 1
  if group_deltas[group] == 0
    return
  endif
  const can_percolate_right = min(group_deltas[group : ]) == 0
  const can_percolate_left = min(group_deltas[0 : group]) == 0
  const group_windows = layout.windows[group]
  if group_windows[-1] != parent && group_windows[-1] != child && can_percolate_right
    this.PercolateFrom(layout, group, group_deltas, 1)
    this.BalanceAfterInsert(layout, parent, child)
  elseif group_windows[0] != parent && group_windows[0] != child && can_percolate_left
    this.PercolateFrom(layout, group, group_deltas, -1)
    this.BalanceAfterInsert(layout, parent, child)
  elseif can_percolate_right
    this.PercolateFrom(layout, group, group_deltas, 1)
  elseif can_percolate_left
    this.PercolateFrom(layout, group, group_deltas, -1)
  endif
enddef

def CaptureEnv(): dict<any>
  return {'winman_explorer_width': g:winman_explorer_width, 'winman_window_width': g:winman_window_width, 'winman_explorer_filetype': g:winman_explorer_filetype, 'columns': &columns, 'window': win_getid(), 'previous_window': win_getid(winnr('#')), 'layout': Layout(), 'filetypes': Filetypes(), 'window_count': winnr('$')}
enddef

export def g:AfterOpen(env: dict<any> = CaptureEnv())
  if env.window_count == 1
    return
  endif
  if IsExplorer(env, env.window)
    MoveToExplorerPosition(env.layout, env.window)
    return
  endif
  const max_groups = MaxGroups(env.columns, env.winman_window_width)
  const has_explorer = HasExplorer(env)
  if env.window_count <= max_groups + (has_explorer ? 1 : 0)
    WinSplitMove(env.layout, env.window, env.previous_window, true, true)
    return
  endif
  if IsExplorer(env, env.previous_window)
    WinSplitMove(env.layout, env.window, env.layout[1][0], false, false)
  else
    const target_group = LocationOf(env, env.previous_window)[0]
    var open_below = (target_group + (has_explorer ? 1 : 0)) % 2 == 0
    WinSplitMove(env.layout, env.window, env.previous_window, false, open_below)
  endif
enddef
