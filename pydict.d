module pydict;

import core.memory;
import core.exception;
import std.traits;
import core.stdc.string : memset;
import std.conv;
import std.random;
import std.stdio;


template isPointer(T:T*) {
    enum bool isPointer = true;
}

template isPointer(T) {
    enum bool isPointer = false;
}

class PyDict(K, V)
{
private:

	//ulong, double etc. on 32bit
	struct BigPODWrapper(T)
	{
		T data;
		size_t hash;
		
		void ctor()
		{
			static assert(T.sizeof >= size_t.sizeof);
			
			hash = typeid(T).getHash(&data);
			
			//will work for ulong with additional hash
			//hash = *cast(size_t*) &data + (cast(size_t*) &data)[1];
			
			//avoid special hashes
			if(isSpecialKey(this)) hash += 2;
		}
		
		void markDummy()
		{
			this.hash = cast(T) dummy_hash;
		}

		alias typeof(this) TT;
		static bool cmp1(TT a, TT b) { return a.data == b.data; }
		static bool cmp2(TT a, TT b) { return false; }
		static bool cmp3(TT a, TT b) { return a.data == b.data; }
	}

	//byte, uint etc. on 32bit
	struct SmallPODWrapper(T)
	{
		T data;
		alias data hash;
		
		void ctor()
		{
			static assert(T.sizeof <= size_t.sizeof);// && !isPointerType!(T));
		}
		
		void markDummy()
		{
			this.data = cast(T) dummy_hash;
		}

		alias typeof(this) TT;
		static bool cmp1(TT a, TT b) { return a.data == b.data; }
		static bool cmp2(TT a, TT b) { return false; }
		static bool cmp3(TT a, TT b) { return a.data == b.data; }
	}

	struct PointerWrapper(T)
	{
		T data;
		
		void ctor()
		{
			static assert(isReferenceType!(T));
		}
		
		void markDummy()
		{
			void* tmp = cast(void*) dummy_hash;
			this.data = cast(T) tmp;
		}
		
		size_t hash() { return cast(size_t) cast(void*) data; }
		
		alias typeof(this) TT;
		static bool cmp1(TT a, TT b) { return a.data is b.data; }
		static bool cmp2(TT a, TT b)
		{
			static if(is(a.opEquals))
			{
				return a.opEquals(b);
			}
			else 
			{
				return false;
			}
		}
		static bool cmp3(TT a, TT b)
		{
			static if(is(a.opEquals))
			{
				return a.data is b.data || a.opEquals(b);
			}
			else 
			{
				return a.data is b.data;
			}
		}
	}

	struct ArrayWrapper(T)
	{
		T data;
		size_t hash;
		
		void ctor()
		{
			static assert(isDynamicArray!(T) || isStaticArray!(T));
			
			if(data.length == 0)
			{
				if(cast(size_t) cast(void*) data.ptr == unused_hash)
				{
					hash = unused_hash;
					return;
				}
				else if(cast(size_t) cast(void*) data.ptr == dummy_hash)
				{
					hash = dummy_hash;
					return;
				}
			}
			
			//hash function
			ubyte[] a = cast(ubyte[]) data;
			auto len = a.length + 1;
			ubyte* p = cast(ubyte *) a.ptr;
			hash = *p << 7;
			while (--len > 0)
			{
				hash = (1000003 * hash) ^ *p++;
			}
			hash ^= a.length;
			
			//avoid special hashes
			if(isSpecialKey(this)) hash += 2;
		}
		
		void markDummy()
		{
			this.hash = dummy_hash;
			this.data = null;
		}
		
		alias typeof(this) TT;
		static bool cmp1(TT a, TT b) { return (a.hash == b.hash && a.data == b.data); }
		static bool cmp2(TT a, TT b) { return false; }
		static bool cmp3(TT a, TT b) { return (a.hash == b.hash && a.data == b.data); }
	}

	/*
	struct StructWrapper(T)
	{
		size_t hash;
		T data;
		
		void ctor()
		{
			this.hash = typeid(T).getHash(&data);
		}
		
		//set dummy
		void markDummy()
		{
			this.hash = hash;
			this.data = T.init;
		}
		
		T getData() { return data; }
		size_t getHash() { return hash; }
		
		alias typeof(this) TT;
		static bool cmp1(TT a, TT b) { return typeid(T).equals(&a.data, &b.data); }
		static bool cmp2(TT a, TT b) { return false; }
		static bool cmp3(TT a, TT b) { return typeid(T).equals(&a.data, &b.data); }
	}
	*/

	struct GenericWrapper(T)
	{
		T data;
		size_t hash;
		
		void ctor()
		{
			this.hash = typeid(T).getHash(&data);
		}
		
		void markDummy()
		{
			this.hash = 1;
			this.data = T.init;
		}
		
		size_t getHash() { return hash; }
		
		alias typeof(this) TT;
		static bool cmp1(TT a, TT b) { return cast(bool) typeid(T).equals(&a.data, &b.data); }
		static bool cmp2(TT a, TT b) { return false; }
		static bool cmp3(TT a, TT b) { return cast(bool) typeid(T).equals(&a.data, &b.data); }
	}

	template SelectKeyWrapper(K)
	{
		static if (isDynamicArray!(K) || isStaticArray!(K))
		{
			alias ArrayWrapper!(K) type;
		}
		else static if (isPointer!(K))
		{
			alias PointerWrapper!(K) type;
		}
		else static if (K.sizeof <= size_t.sizeof)
		{
			//fits into a register
			alias SmallPODWrapper!(K) type;
		}
		else static if (K.sizeof > size_t.sizeof)
		{
			alias BigPODWrapper!(K) type;
		}
		else
		{
			//uses TypeInfo
			alias GenericWrapper!(K) type;
		}
	}

	//key wrapper type
	alias SelectKeyWrapper!(K).type KW;

	//need to be 0 for the algorithm to terminate
	static const size_t unused_hash = 0; 
	static const size_t dummy_hash = 1;

	//need to be a power of two
	static const size_t MINSIZE = 8;
	static const size_t PERTURB_SHIFT = 5;

	struct Entry
	{
		KW key;
		V value;
	}
	
	//active + dummy entries
	size_t fill = 0;
	
	//active entries
	size_t used = 0;

	/*
	* The table contains mask + 1 slots, and that's a power of 2.
	* We store the mask instead of the size because the mask
	* is more frequently needed.
	*/
	size_t mask = MINSIZE - 1;
	
	//table of size 2**n
	Entry[] table;

	/*
	* Since this.table can't hold entries for both special keys,
	* they have to be stored and handled separately.
	*/
	bool is_unused = false;
	KW unused_key = KW.init;
	V unused_value = V.init;
	
	bool is_dummy = false;
	KW dummy_key = KW.init;
	V dummy_value = V.init;

	public this()
	{
		this.table = new Entry[MINSIZE];
	}
	
	~this()
	{
		delete this.table;
	}

	/*
	* Any key that is not special is active.
	*/
	private static bool isActiveKey(KW key)
	{
		return (key.hash > 1);
	}
	
	private static bool isDummyKey(KW key)
	{
		return (key.hash == dummy_hash);
	}
	
	private static bool isUnusedKey(KW key)
	{
		return (key.hash == unused_hash);
	}
	
	private static bool isSpecialKey(KW key)
	{
		return (key.hash < 2);
	}
	
	/*
	* Lookup an entry in the table.
	* This is the workhorse.
	*/
	private Entry* lookdict(KW key)
	{
		assert(!isSpecialKey(key));
		
		size_t hash = key.hash;
		
		size_t perturb = void;
		Entry *freeslot = void;
		size_t mask = this.mask;
		Entry *ep0 = this.table.ptr;
		
		size_t i = hash & mask;
		Entry *ep = &ep0[i];
		
		/*
		* This first lookup will succeed in the very most cases.
		*/
		if (isUnusedKey(ep.key) || KW.cmp1(ep.key, key))
		{
			return ep;
		}
		
		if (isDummyKey(ep.key))
		{
			freeslot = ep;
		}
		else
		{
			if (KW.cmp2(ep.key, key))
			{
				return ep;
			}
			
			freeslot = null;
		}
		
		/*
		* In the loop, key == dummy is by far (factor of 100s) the
		* least likely outcome, so test for that last.
		*/
		for (perturb = hash; ; perturb >>= PERTURB_SHIFT)
		{
			i = (i << 2) + i + perturb + 1;
			ep = &ep0[i & mask];
			
			if (isUnusedKey(ep.key))
			{
				return (freeslot is null) ? ep : freeslot;
			}
			
			if (KW.cmp3(ep.key, key))
			{
				return ep;
			}
			
			if (freeslot is null && isDummyKey(ep.key))
			{
				freeslot = ep;
			}
		}
		assert(0);	//never reached
	}
	
	public V* opIn_r(K k)
	{
		//wrap
		auto key = KW(k);
		key.ctor();
		
		if (isSpecialKey(key))
		{
			if (isUnusedKey(key))
			{
				return is_unused ? &unused_value : null;
			}
			else //must be dummy
			{
				assert(isDummyKey(key));
				return is_dummy ? &dummy_value : null;
			}
			assert(0);
		}
		
		Entry* ep = lookdict(key);
		assert(ep);
		
		if (isActiveKey(ep.key))
		{
			return &ep.value;
		}
		else
		{
			return null;
		}
	}

	public void opIndexAssign(V value, K k)
	{
		assert(this.fill <= this.mask);  //algorithm need at least one empty slot

		//wrap key
		auto key = KW(k);
		key.ctor();
		
		if (isSpecialKey(key))
		{
			if (isUnusedKey(key))
			{
				is_unused = true;
				unused_key = key;
				unused_value = value;
				return;
			}
			else //must be dummy
			{
				assert(isDummyKey(key));
				is_dummy = true;
				dummy_key = key;
				dummy_value = value;
				return;
			}
		}
		
		Entry* ep = lookdict(key);
		assert(ep);
		
		if (isActiveKey(ep.key))
		{
			ep.value = value;
		}
		else
		{
			if (isUnusedKey(ep.key))
			{
				++this.fill;
			}
			else
			{
				assert(isDummyKey(ep.key));
			}
			
			ep.key = key;
			ep.value = value;
			
			++this.used;
			checkLoad();
		}
	}

	/*
	* Check load factor and allocate new table
	*/
	private void checkLoad()
	{
		//Make table bigger if load factor > 3/4.
		//This can also result in smaller table if there are many dummy entries)
		if (this.fill * 4 >= (this.mask + 1) * 3) //load factor is 3/4
		{
			dictresize(2 * this.used);
		}
		/*
		//make table smaller, table size > MINSIZE and load factor is < 1/8
		else if ((this.mask + 1) > MINSIZE && this.fill * 4 < (this.mask + 1))
		{
			dictresize(this.used / (this.used > 50000 ? 4 : 2));
		}*/
	}
	
	public void remove(K k)
	{
		//wrap
		auto key = KW(k);
		key.ctor();
		
		if (isSpecialKey(key))
		{
			if (isUnusedKey(key))
			{
				is_unused = false;
				unused_value = V.init;
				unused_key = KW.init;
				return;
			}
			else //must be dummy
			{
				assert(isDummyKey(key));
				is_dummy = false;
				dummy_value = V.init;
				dummy_key = KW.init;
				return;
			}
		}
		
		Entry* ep = lookdict(key);
		assert(ep);
		
		ep.key.markDummy();
		ep.value = V.init; //not needed for POD?
		--this.used;
	}
	
	private void dictresize(size_t minused)
	{

		Entry[MINSIZE] small_copy;

		// Find the smallest table size > minused and size == 2**n.
		size_t newsize = MINSIZE; 
		while(newsize <= minused)
		{
			newsize <<= 1;
		}
		
		// Get space for a new table.
		Entry[] oldtable = this.table;
		assert(oldtable !is null);
		
		//newtable = cast(Entry*) GC.malloc(Entry.sizeof * newsize);
		Entry[] newtable = new Entry[newsize];
		
		assert(newtable);
		assert(newtable.ptr != oldtable.ptr);
		
		this.table = newtable;
		this.mask = newsize - 1;
		
		//memset(newtable, 0, Entry.sizeof * newsize);
		
		this.used = 0;
		size_t i = this.fill;
		this.fill = 0;

		//copy the data over; filter out dummies
		for (Entry* ep = oldtable.ptr; i > 0; ep++)
		{
			if (isActiveKey(ep.key))
			{
				--i;
				insertdict_clean(ep.key, ep.value);
			}
			else if (isDummyKey(ep.key))
			{
				--i;
			}
		}

		delete oldtable;
	}
	
	/*
	* Insert an item which is known to be absent from the dict. 
	* This routine also assumes that the dict contains no deleted entries.
	*/
	private void insertdict_clean(KW key, V value)
	{
		assert(!isSpecialKey(key));
		
		size_t hash = key.hash;
		size_t perturb = hash;
		size_t mask = this.mask;
		Entry* ep0 = this.table.ptr;

		size_t i = hash & mask;
		Entry* ep = &ep0[i];
        
		while(!isUnusedKey(ep.key))
		{
			i = (i << 2) + i + perturb + 1;
			ep = &ep0[i & mask];
			perturb >>= PERTURB_SHIFT;
		}
        
		++this.fill;
		ep.key = key;
		ep.value = value;
		++this.used;
	}
	
	/*
	* We use this template to cast a static array to a dynamic one in opApply,
	* since the dmd specs don't allow them as ref parameters :F
	*/
	private template DeconstArray(T)
	{
		static if(isStaticArray!(T))
		{
			alias typeof(T.init[0])[] type; //the equivalent dynamic array
		}
		else
		{
			alias T type;
		}
	}
	
	alias DeconstArray!(K).type K_;
	alias DeconstArray!(V).type V_;
	
	public int opApply(int delegate(ref V_ value) dg)
	{
		return opApply((ref K_ k, ref V_ v) { return dg(v); });
	}
	
	public int opApply(int delegate(ref K_ key, ref V_ value) dg)
	{
		Entry* ep = this.table.ptr;
		int result = 0;
		
		if (is_unused)
		{
			auto key = cast(K_) unused_key.data;
			auto value = cast(V_) unused_value;
			result = dg(key, value);

			if(result != 0)
			{
				return result;
			}
		}
		
		if (is_dummy)
		{
			auto key = cast(K_) dummy_key.data;
			auto value = cast(V_) dummy_value;
			result = dg(key, value);
			
			if(result != 0)
			{
				return result;
			}
		}
		
		for (size_t i = 0; i <= this.mask; ++i)
		{
			if (isSpecialKey(ep[i].key))
			{
				continue;
			}
			
			auto key = cast(K_) ep[i].key.data;
			auto value = cast(V_) ep[i].value;
			result = dg(key, value);
			
			if (result != 0)
			{
				break;
			}
		}
		
		return result;
	}
	
	/*
	* Get number of active entries stored.
	*/
	public size_t size()
	{
		return used + is_dummy + is_unused;
	}
	
	public K[] keys()
	{
		K[] keys = new K[](this.size());
		Entry* ep = this.table.ptr;
		size_t length = this.mask;
		size_t n = 0;
		
		if (is_unused) keys[n++] = cast(K_) unused_key.data;
		if (is_dummy) keys[n++] = cast(K_) dummy_key.data;
		
		for (size_t i = 0; i < length; ++i)
		{
			if (isSpecialKey(ep[i].key))
			{
				continue;
			}
			keys[n] = ep[i].key.data;
			++n;
		}
	
		return keys;
	}
	
	public V[] values()
	{
		V[] values = new V[](this.size());
		Entry* ep = this.table.ptr;
		size_t length = this.mask;
		size_t n = 0;
		
		if (is_unused) values[n++] = unused_value;
		if (is_dummy) values[n++] = dummy_value;
		
		for (size_t i = 0; i < length; ++i)
		{
			if (isSpecialKey(ep[i].key))
			{
				continue;
			}
			values[n] = ep[i].value;
			++n;
		}
		
		return values;
	}
}
