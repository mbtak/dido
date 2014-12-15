module dido.buffer.buffer;

import std.file;
import std.string;
import std.array;
import std.conv;
import std.algorithm;

import dido.buffer.selection;
import dido.buffer.buffercommand;
import dido.buffer.bufferiterator;


// text buffers

final class Buffer
{
private:
    string _filepath;
    SelectionSet _selectionSet;
    dstring[] lines;
    int _historyIndex; // where we are in history
    BufferCommand[] _history;
    bool _hasBeenLoaded;
    int _longestLine;

public:

    // create new
    this()
    {
        lines = ["\n"d];
        _selectionSet = new SelectionSet(this);
        _filepath = null;
        _hasBeenLoaded = true;
        updateLongestLine();
    }

    this(string filepath)
    {
        lines = ["\n"d];
        _selectionSet = new SelectionSet(this);
        _filepath = filepath;
        _hasBeenLoaded = false;
        updateLongestLine();
    }

    void clearContent()
    {
        lines = ["\n"d];
        _selectionSet = new SelectionSet(this);
        _filepath = null;
        _hasBeenLoaded = true;
        updateLongestLine();
    }


    void ensureLoaded()
    {
        if (!_hasBeenLoaded)
        {
            assert(_filepath !is null);
            loadFromFile(_filepath);
            _hasBeenLoaded = true;
        }
    }

    // load file in buffer, non-conforming utf-8 is lost
    void loadFromFile(string path)
    {
        lines = readTextFile(path, _longestLine);
    }

    ubyte[] toSource()
    {
        ubyte[] result;
        for (size_t i = 0; i < lines.length; ++i)
        {
            string line = to!string(lines[i]);

            // don't output virtual EOL of last line
            assert(line.length > 0);
            if (i + 1 == lines.length)
                line = line[0..$-1];

            version(Windows)
            {
                if (line.length > 0 && line[$-1] == '\n')
                    line = line[0..$-1] ~ "\r\n";
                result ~= line;
            }
        }
        return result;
    } 
    
    dstring getContent()
    {
        return getSelectionContent(Selection(begin(), end()));
    }

    // save file using OS end-of-lines
    void saveToFile(string path)
    {
        std.file.write(path, toSource());
    }

    int numLines() pure const nothrow
    {
        return cast(int)(lines.length);
    }

    int lineLength(int lineIndex) pure const nothrow
    {
        return cast (int) lines[lineIndex].length;
    }

    int getLongestLineLength() pure const nothrow
    {
        return lineLength(_longestLine);
    }

    // maximum column allowed for cursor on this line
    int maxColumn(int lineIndex) pure const nothrow
    {
        return cast(int) lines[lineIndex].length - 1;
    }

    inout(dstring) line(int lineIndex) pure inout nothrow
    {
        return lines[lineIndex];
    }

    dstring cut()
    {
        dstring result = copy();
        deleteSelection(false);
        return result;
    }

    dstring copy()
    {
        dstring result = ""d;
        int sellen = cast(int)_selectionSet.selections.length;
        for (int i = 0; i < sellen; ++i)
        {
            if (i > 0)
                result ~= '\n';
            result ~= getSelectionContent(_selectionSet.selections[i]);
        }
        return result;
    }

    void paste(dstring clipboardContent)
    {
        // removes \r from clipboard string (system might add it for interop reasons)
        dstring clearedClipBoard;
        int l = 0;
        for (int i = 0; i < cast(int)(clipboardContent.length); ++i)
            if (clipboardContent[i] != '\r')
                clearedClipBoard ~= clipboardContent[i];

        if (_selectionSet.selections.length > 1)
        {
            dstring[] byLineContent = splitLines(clearedClipBoard);
            bySelectionEdit( (int i) 
                            {
                                if (i < byLineContent.length)
                                    return byLineContent[i];
                                else
                                    return ""d;
                            } );
        }
        else
        {
            bySelectionEdit( (int i) 
                            {
                                return clearedClipBoard;
                            } );
        }
    }

    void undo()
    {
        while (_historyIndex > 0)
        {
            _historyIndex--;
            if (reverseCommand(_history[_historyIndex]))
                break;
        }
    }

    void redo()
    {
        int barrierFound = 0;
        while (_historyIndex < _history.length)
        {
            if (_history[_historyIndex].type == BufferCommandType.BARRIER)
                barrierFound++;

            if (barrierFound >= 2)
                return;

            applyCommand(_history[_historyIndex]);
            _historyIndex++;
        }
    }

    bool isBoundToFileName()
    {
        return _filepath !is null;
    }

    void moveSelectionHorizontal(int dx, bool shift)
    {
        foreach(ref sel; _selectionSet.selections)
        {
            sel.edge = sel.edge + dx;            

            if (!shift)
                sel.anchor = sel.edge;
        }
        _selectionSet.normalize();
    }

    void moveSelectionVertical(int dy, bool shift)
    {
        foreach(ref sel; _selectionSet.selections)
        {
            sel.edge.cursor = clampCursor(Cursor(sel.edge.cursor.line + dy, sel.edge.cursor.column));

            if (!shift)
                sel.anchor = sel.edge;
        }
        _selectionSet.normalize();
    }

    // move by words
    void moveSelectionWord(int dx, bool shift)
    {   
        assert(dx == -1 || dx == 1);
        foreach(ref sel; _selectionSet.selections)
        {
            BufferIterator edge = sel.edge;

            if (dx == -1 && edge.canBeDecremented)
                --edge;

            static bool isSpace(dchar ch)
            {
                static immutable dstring spaces = " \n\t\r"d;
                for (size_t i = 0; i < spaces.length; ++i)
                    if (ch == spaces[i])
                        return true;
                return false;
            }

            static bool isOperator(dchar ch)
            {
                static immutable dstring operators = "+-=><^,$|&`/@.\"[](){}?:\'\\"d;
                for (size_t i = 0; i < operators.length; ++i)
                    if (ch == operators[i])
                        return true;
                return false;
            }

            static bool isAlnum(dchar ch)
            {
                return !(isSpace(ch) || isOperator(ch));
            }

            bool wentThroughLineBreak = false;

            while(true)
            {
                dchar ch = edge.read();
                if (ch == '\n')
                    wentThroughLineBreak = true;
                if (! (isSpace(ch) && edge.canGoInDirection(dx)) )
                    break;
                edge += dx;
            }

            if (!wentThroughLineBreak)
            {
                bool isOp = isOperator(edge.read);
                if (isOp)
                {
                    while( isOperator(edge.read) && edge.canGoInDirection(dx) )
                        edge += dx;
                }
                else
                {
                    while( isAlnum(edge.read) && edge.canGoInDirection(dx) )
                        edge += dx;
                }
            }

            if (dx == -1 && edge.canBeIncremented)
                ++edge;

            sel.edge = edge;
            if (!shift)
                sel.anchor = sel.edge;
            _selectionSet.normalize();
        }
    }


    void moveSelectionToBufferStart(bool shift)
    {
        foreach(ref sel; _selectionSet.selections)
        {
            sel.edge = begin();
            if (!shift)
                sel.anchor = sel.edge;
        }
        _selectionSet.normalize();
    }

    void moveSelectionToBufferEnd(bool shift)
    {
        foreach(ref sel; _selectionSet.selections)
        {
            sel.edge = end();
            if (!shift)
                sel.anchor = sel.edge;
        }
        _selectionSet.normalize();
    }

    void selectAll()
    {
        foreach(ref sel; _selectionSet.selections)
        {
            sel.anchor = begin();
            sel.edge = end();
        }
        _selectionSet.normalize();
    }

    Cursor clampCursor(Cursor cursor)
    {
        Cursor result;
        result.line = min(max(cursor.line, 0), numLines() - 1);
        result.column = min(max(cursor.column, 0), maxColumn(result.line));
        return result;
    }

    // Add a new area-less selection
    void extendSelectionVertical(int dy)
    {
        Selection sel;
        if (dy > 0)
            sel = _selectionSet.selections[$-1];
        else
            sel = _selectionSet.selections[0];

        sel.edge.cursor = clampCursor(Cursor(sel.edge.cursor.line + dy, sel.edge.cursor.column));

        sel.anchor = sel.edge;
        _selectionSet.selections ~= sel;
        _selectionSet.normalize();
    }

    void addNewSelection(int line, int column, bool keepExistingSelections)
    {
        BufferIterator it = BufferIterator(this, clampCursor(Cursor(line, column)));
        Selection newSel = Selection(it, it);
        assert(newSel.isValid);

        if (keepExistingSelections)
            _selectionSet.selections ~= newSel;
        else
            _selectionSet.selections = [ newSel ];
        _selectionSet.normalize();
    }

    void moveToLineBegin(bool shift)
    {
        foreach(ref sel; _selectionSet.selections)
        {
            sel.edge.cursor.column = 0;

            if (!shift)
                sel.anchor = sel.edge;
        }
        _selectionSet.normalize();
    }

    void moveToLineEnd(bool shift)
    {
        foreach(ref sel; _selectionSet.selections)
        {
            sel.edge.cursor.column = maxColumn(sel.edge.cursor.line);

            if (!shift)
                sel.anchor = sel.edge;
        }
        _selectionSet.normalize();
    }

    inout(SelectionSet) selectionSet() inout
    {
        return _selectionSet;
    }

    void insertChar(dchar ch)
    {
        dstring content = ""d ~ ch;
        bySelectionEdit( (int i) 
                         { 
                             return content; 
                         } );
    }

    void insertTab()
    {
        dstring content = "    "d;
        bySelectionEdit( (int i) 
                        { 
                            return content;
                        } );
    }

    // selection with area => delete selection
    // else delete character at cursor or before cursor
    void deleteSelection(bool isBackspace)
    {
        enqueueBarrier();
        enqueueSaveSelections();

        for (int i = 0; i < _selectionSet.selections.length; ++i)
        {
            Selection selectionBeforeEdit = _selectionSet.selections[i];
            Selection selectionAfterEdit;
            if (selectionBeforeEdit.hasSelectedArea())
            {
                selectionAfterEdit = enqueueEdit(selectionBeforeEdit, ""d);
            }
            else
            {
                Selection oneCharSel = selectionBeforeEdit;
                if (isBackspace && oneCharSel.anchor.canBeDecremented)
                    oneCharSel.anchor--;
                else if (oneCharSel.edge.canBeIncremented)
                    oneCharSel.edge++;

                assert(oneCharSel.isValid());
                if (oneCharSel.hasSelectedArea())
                {
                    selectionBeforeEdit = oneCharSel;
                    selectionAfterEdit = enqueueEdit(oneCharSel, ""d);
                }
                else
                    selectionAfterEdit = selectionBeforeEdit;
            }

            _selectionSet.selections[i] = selectionAfterEdit;

            // apply offset to all subsequent selections
            for (int j = i + 1; j < _selectionSet.selections.length; ++j)
            {
                _selectionSet.selections[j].translateByEdit(selectionBeforeEdit.sorted.edge, selectionAfterEdit.sorted.edge);                
            }

            for (int j = 0; j < _selectionSet.selections.length; ++j)
            {
                assert(_selectionSet.selections[j].isValid());
            }
        }
        _selectionSet.keepOnlyEdge();
        _selectionSet.normalize();
        enqueueSaveSelections();
    }

    string filePath()
    {
        if (_filepath is null)
            return "Untitled";
        else
            return _filepath;
    }

    void cleanup()
    {
        enqueueBarrier();
        enqueueSaveSelections();

        _selectionSet.keepOnlyFirst();
        _selectionSet.selections[0].edge.cursor = Cursor(0, 0);
        _selectionSet.selections[0].anchor.cursor = Cursor(0, 0);

        for (int i = 0; i < lines.length; ++i)
        {
            bool whitespace = true;
            int start = i == lines.length - 1 ? cast(int)(lines[i].length) - 1 : cast(int)(lines[i].length) - 2;
            for (int j = start; j >= 0; --j)
            {
                dchar ch = lines[i][j];
                if (whitespace && ch == ' ')
                {
                    Selection sel = Selection(BufferIterator(this, Cursor(i, j)), BufferIterator(this, Cursor(i, j + 1)));
                    enqueueEdit(sel, ""d);
                }
                else
                    whitespace = false;

                if (ch == '\t')
                {
                    Selection sel = Selection(BufferIterator(this, Cursor(i, j)), BufferIterator(this, Cursor(i, j + 1)));
                    enqueueEdit(sel, "    "d);
                }
            }
        }
        _selectionSet.normalize();
        enqueueSaveSelections();
    }

    struct Hit 
    {
        bool charInSelection;
        bool cursorThere;
        Selection selInside;
    }

    // return a combination of Hit flags
    Hit intersectsSelection(Cursor cursor)
    {
        Hit hit;
        hit.charInSelection = false;
        hit.cursorThere = false;

        int min = 0;
        int max =  cast(int) _selectionSet.selections.length - 1;
        while(min <= max) // assume sorted selections
        {
            int middle = (min + max + 1) / 2;
            Selection sel = _selectionSet.selections[middle];
            Selection ssel = sel.sorted();

            if (cursor == sel.edge.cursor)
                hit.cursorThere = true;

            if (cursor < ssel.anchor.cursor)
            {
                max = middle - 1;
            }
            else if (cursor >= ssel.edge.cursor)
            {
                min = middle + 1;
            }
            else if (cursor >= ssel.anchor.cursor && cursor < ssel.edge.cursor)
            {
                hit.charInSelection = true;
                hit.selInside = sel;
                break;
            }
            else
                assert(false);
        }
        return hit;
    }


    invariant()
    {
        if (_hasBeenLoaded)
        {
            // at least one line
            if (lines.length < 1)
            {
                assert(false);
            }

            // every line finish by a \n
            for (size_t i = 0; i < lines.length; ++i)
            {
                dstring l = lines[i];
                if (l.length == 0)
                {
                    assert(false);
                }
                if (l[$-1] != '\n')
                {
                    assert(false);
                }
            }
        }
    }

package:

    BufferIterator begin()
    {
        return BufferIterator(this, Cursor(0, 0));
    }

    BufferIterator end()
    {
        return BufferIterator(this, Cursor(cast(int) lines.length - 1, maxColumn(cast(int) lines.length - 1)));
    }

private:

    void updateLongestLine() pure nothrow
    {
        int maxLength = 0;
        _longestLine = 0;

        for (int i = 0; i < cast(int)lines.length; ++i)
        {
            if (lines[i].length > maxLength)
            {
                maxLength = cast(int) lines[i].length;
                _longestLine = i;
            }
        }
    }

    void pushCommand(BufferCommand command)
    {
        // strip previous history, add command
        _history = _history[0.._historyIndex] ~ command;
        _historyIndex = cast(int) _history.length;
    }

    // replace a Selection content by a new content
    // returns a cursor Selection just after the newly inserted part
    Selection replaceSelectionContent(Selection selection, dstring content)
    {
        Selection sel = selection.sorted();
        erase(sel.anchor, sel.edge);
        BufferIterator after = insert(sel.anchor, content);
        return Selection(sel.anchor, after);
    }

    // Gets content of a selection
    dstring getSelectionContent(Selection selection)
    {
        Selection sel = selection.sorted();
        dstring result;

        // TODO PERF this could be faster by appending larger chunks
        for (BufferIterator it = sel.anchor; it != sel.edge; ++it)
            result ~= it.read();

        return result;
    }

    BufferIterator insert(BufferIterator pos, dstring content)
    {
        foreach(dchar ch ; content)
            pos = insert(pos, ch);
        return pos;
    }

    // insert a single char
    // return an iterator after the inserted char
    BufferIterator insert(BufferIterator pos, dchar content)
    {
        assert(pos.isValid());

        if (content == '\n')
        {
            int col = pos.cursor.column;
            int line = pos.cursor.line;
            bool shouldUpdateLongestLine = (line == _longestLine);
            bool shouldAddOneToLongestLine = (line < _longestLine);
            dstring thisLine = lines[line];
            lines.insertInPlace(line, thisLine[0..col].idup ~ '\n'); // copy sub-part addind a \n
            lines[line + 1] = lines[line + 1][col..$]; // next line becomes everything else

            // in case we broke the longest line, linear search of longest line
            if (shouldAddOneToLongestLine)
                _longestLine++;

            if (shouldUpdateLongestLine)
                updateLongestLine();

            return BufferIterator(pos.buffer, Cursor(line + 1, 0));
        }
        else
        {
            int line = pos.cursor.line;
            int column = pos.cursor.column;
            dstring oneCh = (&content)[0..1].idup;
            replaceInPlace(lines[line], column, column, oneCh);

            // check that longest line has changed
            if (lines[line].length > getLongestLineLength())
                _longestLine = line;

            return BufferIterator(pos.buffer, Cursor(line, column + 1));
        }
    }

    // delete a single char
    void erase(BufferIterator pos)
    {
        dchar chErased = pos.read();
        if (chErased == '\n')
        {
            int line = pos.cursor.line;
            int column = pos.cursor.column;
            dstring newLine = lines[line][0..$-1] ~ lines[line+1];
            replaceInPlace(lines, line, line + 2, [ newLine ]);
            updateLongestLine();
        }
        else
        {
            int line = pos.cursor.line;
            int column = pos.cursor.column;
            replaceInPlace(lines[line], column, column + 1, ""d);

            // check that it's still the longest line
            if (_longestLine == line)
                updateLongestLine();
        }
    }

    void erase(BufferIterator begin, BufferIterator end)
    {
        while (begin < end)
        {
            --end;
            erase(end);
        }
    }

    void applyCommand(BufferCommand command)
    {
        final switch(command.type) with (BufferCommandType)
        {
            case CHANGE_CHARS:
                replaceSelectionContent(command.changeChars.oldSel, command.changeChars.newContent);
                break;

            case SAVE_SELECTIONS:
                // also restore them, useful in redo sequences
                _selectionSet.selections = command.saveSelections.selections.dup;
                break;

            case BARRIER:
                // do nothing
                break;
        }
    }

    // returns true if it was a barrier
    bool reverseCommand(BufferCommand command)
    {
        final switch(command.type) with (BufferCommandType)
        {
            case CHANGE_CHARS:
                replaceSelectionContent(command.changeChars.newSel, command.changeChars.oldContent);
                return false;

            case SAVE_SELECTIONS:
                // restore selections
                _selectionSet.selections = command.saveSelections.selections.dup;
                return false;

            case BARRIER:
                return true;
        }
    }

    void enqueueBarrier()
    {
        pushCommand(barrierCommand());
    }

    void enqueueSaveSelections()
    {
        pushCommand(saveSelectionsCommand(_selectionSet.selections));
    }

    Selection enqueueEdit(Selection selection, dstring newContent)
    {
        dstring oldContent = getSelectionContent(selection);
        Selection newSel = replaceSelectionContent(selection, newContent);
        BufferCommand command = changeCharsCommand(selection, newSel, oldContent, newContent);
        pushCommand(command);
        return Selection(newSel.edge);
    }

    void bySelectionEdit(dstring delegate(int i) selectionContent)
    {
        enqueueBarrier();
        enqueueSaveSelections();

        for (int i = 0; i < _selectionSet.selections.length; ++i)
        {
            Selection selectionBeforeEdit = _selectionSet.selections[i];
            Selection selectionAfterEdit = enqueueEdit(selectionBeforeEdit, selectionContent(i)).sorted();

            // apply offset to all subsequent selections
            // TODO PERF this is quadratic behaviour
            for (int j = i + 1; j < _selectionSet.selections.length; ++j)
            {
                _selectionSet.selections[j].translateByEdit(selectionBeforeEdit.sorted.edge, selectionAfterEdit.sorted.edge);                
            }
            _selectionSet.selections[i] = selectionAfterEdit;
        }
        _selectionSet.normalize();
        enqueueSaveSelections();
    }
}

private
{
  

    // removes BOM, sanitize Unicode, and split on line endings
    dstring[] readTextFile(string path, out int longestLine)
    {
        string wholeFile = cast(string) std.file.read(path);

        // remove UTF-8 BOM
        if (wholeFile.length > 3 && wholeFile[0] == '\xEF' && wholeFile[1] == '\xBB' && wholeFile[2] == '\xBF')
            wholeFile = wholeFile[3..$];

        // sanitize non-UTF-8 sequences
        import std.encoding : sanitize;
        wholeFile = sanitize(wholeFile);

        dstring wholeFileUTF32 = to!dstring(wholeFile);

        dstring[] lines;
        dstring currentLine;
        longestLine = 0;
        int maxLength = 0;
        int numLine = 0;

        for (size_t i = 0; i < wholeFileUTF32.length; ++i)
        {
            dchar ch = wholeFileUTF32[i];

            if (ch == '\n')
            {
                currentLine ~= '\n';
                if (currentLine.length > maxLength)
                {
                    longestLine = numLine;
                    maxLength = cast(int) currentLine.length;
                }
                lines ~= currentLine.dup;
                numLine++;
                currentLine.length = 0;
            }
            else if (ch == '\r')
            {
                // simply remove them
            }
            else
            {
                currentLine ~= ch;
            }
        }

        // last line must have a virtual line-feed, this simplify things
        currentLine ~= '\n';
        lines ~= currentLine.dup;
        numLine++;
        return lines;
    }
}
