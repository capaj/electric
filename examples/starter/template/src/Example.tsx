import React, { useEffect, useState } from 'react'

import { makeElectricContext, useLiveQuery } from 'electric-sql/react'
import { ElectricDatabase, electrify } from 'electric-sql/wa-sqlite'

import { insecureAuthToken } from 'electric-sql/auth'
import { genUUID } from 'electric-sql/util'

import { DEBUG_MODE, ELECTRIC_URL } from './config'
import { Electric, Items, schema } from './generated/client'

import './Example.css'

const { ElectricProvider, useElectric } = makeElectricContext<Electric>()

export const Example = () => {
  const [ electric, setElectric ] = useState<Electric>()

  useEffect(() => {
    let isMounted = true

    const init = async () => {
      const config = {
        auth: {
          token: insecureAuthToken({user_id: 'dummy'})
        },
        debug: DEBUG_MODE,
        url: ELECTRIC_URL
      }
      const conn = await ElectricDatabase.init('electric.db', '')
      const electric = await electrify(conn, schema, config)

      if (!isMounted) {
        return
      }

      setElectric(electric)
    }

    init()

    return () => {
      isMounted = false
    }
  }, [])

  if (electric === undefined) {
    return null
  }

  return (
    <ElectricProvider db={electric}>
      <ExampleComponent />
    </ElectricProvider>
  )
}

const ExampleComponent = () => {
  const { db } = useElectric()!

  useEffect(() => void db.items.sync(), [])

  const { results } = useLiveQuery(
    db.items.liveMany()
  )

  const addItem = async () => {
    await db.items.create({
      data: {
        value: genUUID(),
      }
    })
  }

  const clearItems = async () => {
    await db.items.deleteMany()
  }

  const items: Items[] = results !== undefined ? results : []

  return (
    <div>
      <div className="controls">
        <button className="button" onClick={ addItem }>
          Add
        </button>
        <button className="button" onClick={ clearItems }>
          Clear
        </button>
      </div>
      {items.map((item: any, index: any) => (
        <p key={ index } className="item">
          <code>{ item.value }</code>
        </p>
      ))}
    </div>
  )
}
